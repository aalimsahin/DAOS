# SPDX-License-Identifier: MIT
%lang starknet

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from starkware.starknet.common.eth_utils import assert_valid_eth_address
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import assert_lt
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math import sign
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.messages import send_message_to_l1
from starkware.starknet.common.syscalls import (get_block_timestamp, get_caller_address)

#####################
## Interfaces
#####################

@contract_interface
namespace IDAOTokenContract:
    func balanceOf(account: felt) -> (balance: Uint256):
    end
end

#####################
## CONSTANTS & TYPES
#####################

# keccak256("send_result_to_l1(felt)")[:4] = 0xc461daf7 = 3294747383
const MESSAGE_SEND_RESULT_TO_L1 = 3294747383

struct ProposalDetails:
  member proposal_index: felt # Index of the proposal
  member to: felt # To
  member value: felt  # Value of proposal
  member deadline: felt  # Timestamp where proposal ends
end

#####################
## STORAGE
#####################

@storage_var
func owner() -> (owner_addr: felt):
end

#Ethereum Contract Address
@storage_var
func l1_contract_address() -> (address: felt):
end

#Token Contract Address
@storage_var
func token_contract_address() -> (address: felt):
end

#Proposal Details
@storage_var
func proposal_details(proposalId: felt) -> (details: ProposalDetails):
end

# Negative Vote Count
@storage_var
func vote_count0(proposalId: felt) -> (counts: felt):
end

# Positive Vote Count
@storage_var
func vote_count1(proposalId: felt) -> (counts: felt):
end

#Check Account Vote
@storage_var
func did_account_vote(acccount:felt, proposalId: felt) -> (counts: felt):
end

#####################
## CONSTRUCTOR
#####################

@constructor
func constructor{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(addr: felt, tokenAddr: felt):
  l1_contract_address.write(addr)
  token_contract_address.write(tokenAddr)

  return()
end

#####################
## VIEWS
#####################

@view
func get_proposal_details{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(proposalId: felt) -> (details: ProposalDetails):
 return proposal_details.read(proposalId)
end

@view
func call_balance_of{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
  }() -> (res : Uint256):
    let (caller: felt) = get_caller_address()
    let (addr:felt) = token_contract_address.read()
    let (res) = IDAOTokenContract.balanceOf(
        contract_address=addr, account=caller
    )
    return (res=res)
end

#####################
## EXTERNALS
#####################

@external
func set_l1_contract_address{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(addr: felt):
  let (caller: felt) = get_caller_address()
  let (owner_of_contract: felt) = owner.read()

  with_attr error_message("You are not owner"):
    assert caller = owner_of_contract
  end

  with_attr error_message("Not a valid address"):
    assert_valid_eth_address(addr)
  end

  l1_contract_address.write(value=addr)
  return ()
end


@external
func set_token_contract_address{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(addr: felt):
  let (caller: felt) = get_caller_address()
  let (owner_of_contract: felt) = owner.read()

  with_attr error_message("You are not owner"):
    assert caller = owner_of_contract
  end

  token_contract_address.write(value=addr)
  return ()
end


@external
func vote{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(  proposalId: felt, choose: felt):
  alloc_locals
  let (proposal:ProposalDetails) = proposal_details.read(proposalId)
  let (caller: felt) = get_caller_address()
  let (vote_count:felt) = did_account_vote.read(caller, proposalId)
  let (block_timestamp:felt) = get_block_timestamp()

  let (local bal: Uint256) = call_balance_of()
  let (balance: felt) = Math64x61_fromUint256(bal)

  with_attr error_message("You need to have DAOToken for voting"):
    assert_lt(0, balance - vote_count)
  end

  with_attr error_message("Invalid deadline"):
    assert_lt(block_timestamp, proposal.deadline)
  end

  if choose == 1:
    let (vote1: felt) = vote_count1.read(proposalId)

    vote_count1.write(proposalId, vote1 + balance)
  else:
    let (vote0: felt) = vote_count0.read(proposalId)
    vote_count0.write(proposalId, vote0 + balance)
  end

  did_account_vote.write(caller, proposalId, balance)

  return ()
end

@external
func send_result_to_l1{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(proposalId: felt ):
  alloc_locals
  let (block_timestamp: felt) = get_block_timestamp()
  let (proposal: ProposalDetails) = proposal_details.read(proposalId)

  let (local l1_claimer: felt) = l1_contract_address.read()

  with_attr error_message("L1 claimer is invalid"):
    assert_valid_eth_address(l1_claimer)
  end

  with_attr error_message("Voting is not finished"):
    assert_lt(block_timestamp, proposal.deadline)
  end

  let (yes: felt) = vote_count1.read(proposalId)
  let (no: felt) = vote_count0.read(proposalId)
  let (result: felt) = sign(yes - no)

  if result != 1:
    result = 0
    return()
  end

  let (message_payload: felt*) = alloc()
  assert message_payload[0] = MESSAGE_SEND_RESULT_TO_L1
  assert message_payload[1] = proposal.proposal_index
  assert message_payload[2] = result

  send_message_to_l1(
    to_address=l1_claimer,
    payload_size=3,
    payload=message_payload)

  return ()
end

#####################
## L1 HANDLERS
#####################

@l1_handler
func start_voting{
  syscall_ptr: felt*,
  pedersen_ptr: HashBuiltin*,
  range_check_ptr
}(
  from_address: felt,
  proposal_index: felt,
  to: felt,
  value: felt,
  deadline: felt
):
  let (block_timestamp: felt) = get_block_timestamp()

  let (l1_address : felt) = l1_contract_address.read()
  assert from_address = l1_address

  with_attr error_message("Invalid Ethereum address"):
    assert_valid_eth_address(to)
  end

  with_attr error_message("Invalid deadline"):
    assert_lt(block_timestamp, deadline)
  end

  proposal_details.write(
    proposalId=proposal_index,
    value=ProposalDetails(
    proposal_index=proposal_index,
    to=to,
    value=value,
    deadline=deadline
    ))
  return ()
end

#####################
## HELPERS
#####################

# Converts a felt to a fixed point value ensuring it will not overflow
func Math64x61_fromFelt {range_check_ptr} (x: felt) -> (res: felt):
    assert_le(x, 2 ** 64)
    assert_le(-(2 ** 64), x)
    return (x * 2 ** 61)
end

# Converts a uint256 value into a fixed point 64.61 value ensuring it will not overflow
func Math64x61_fromUint256 {range_check_ptr} (x: Uint256) -> (res: felt):
    assert x.high = 0
    let (res) = Math64x61_fromFelt(x.low)
    return (res)
end
