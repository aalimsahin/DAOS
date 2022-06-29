// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IStarknetCore.sol";

contract DAO {
    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event SubmitProposal(
        string info,
        uint256 indexed txIndex,
        address indexed to,
        uint256 indexed value,
        uint256 deadline,
        bytes data
    );
    event ConfirmProposal(uint256 indexed txIndex);
    event ExecuteProposal(uint256 indexed txIndex);

    struct Proposal {
        string info; // Description of Purposal
        address to; // Who will it be sent to
        uint256 value; // Quantity to be shipped
        bytes data;
        uint256 deadline; // End Time
        bool executed; // Is it executed?
    }
    // Have the token holders confirmed it?
    mapping(uint256 => bool) public isConfirmed;

    Proposal[] public proposals;

    address public owner;
    // Starknet Core Contract
    IStarknetCore immutable starknetCore;

    // The selector that allows us to start voting on Starknet
    uint256 constant START_VOTING =
        1293457744556376431615471266035226434902724628672358348388241766864848413142;

    // Starknet Voting Address
    uint256 L2CONTRACT_ADDRESS;

    constructor() {
        owner = msg.sender;
        starknetCore = IStarknetCore(
            // Goerli Starknet Core Contract address
            0xde29d060D45901Fb19ED6C6e959EB22d8626708e
        );
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function getProposalCount() public view returns (uint256) {
        return proposals.length;
    }


    function getProposal(uint256 _proposalIndex)
        public
        view
        returns (Proposal memory)
    {
        Proposal storage proposal = proposals[_proposalIndex];

        return proposal;
    }

    function showProposal(uint256 _proposalIndex)
        public
        view
        returns (string memory)
    {
        return proposals[_proposalIndex].info;
    }

    // Add new proposal to contract
    function submitProposal(
        string calldata _info,
        address _to,
        uint256 _value,
        uint256 _deadline,
        bytes memory _data
    ) public onlyOwner {
        uint256 proposalIndex = proposals.length;

        proposals.push(
            Proposal({
                info: _info,
                to: _to,
                value: _value,
                deadline: _deadline,
                data: _data,
                executed: false
            })
        );

        //[TX Index, To, Value, Deadline]
        uint256[] memory payload = new uint256[](4);
        payload[0] = proposalIndex;
        payload[1] = uint256(uint160(_to));
        payload[2] = _value;
        payload[3] = _deadline;

        // sending message to Starknet
        starknetCore.sendMessageToL2(L2CONTRACT_ADDRESS, START_VOTING, payload);

        emit SubmitProposal(
            _info,
            proposalIndex,
            _to,
            _value,
            _deadline,
            _data
        );
    }

    // Get result of the voting from Starknet
    function confirmPurposal(uint256 id, uint256 state) public {
        uint256[] memory rcvPayload = new uint256[](2);
        rcvPayload[0] = id;
        rcvPayload[1] = state; //true-false

        // Get infos from Starknet
        starknetCore.consumeMessageFromL2(L2CONTRACT_ADDRESS, rcvPayload);

        require(id < proposals.length, "Proposal does not exist");
        require(
            proposals[id].deadline < block.timestamp,
            "Voting time is not over"
        );
        require(proposals[id].executed == false, "Proposal executed");

        if (state == 1) isConfirmed[id] = true;
        else isConfirmed[id] = false;

        emit ConfirmProposal(id);
    }

    // Implement proposal if approved
    function executeProposal(uint256 _proposalIndex)
        public
        isPurposalExists(_proposalIndex)
        notExecuted(_proposalIndex)
    {
        require(
            isConfirmed[_proposalIndex] == true,
            "Proposal is not confirmed"
        );
        Proposal storage proposal = proposals[_proposalIndex];

        proposal.executed = true;

        (bool success, ) = proposal.to.call{value: proposal.value}(
            proposal.data
        );
        require(success, "Tx failed");

        emit ExecuteProposal(_proposalIndex);
    }

    // Set Starknet Contract Address
    function setL2Address(uint256 newAddress) public {
        L2CONTRACT_ADDRESS = newAddress;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "You are not owner");
        _;
    }

    modifier isPurposalExists(uint256 _purposalIndex) {
        require(_purposalIndex < proposals.length, "Purposal does not exist");
        _;
    }

    modifier notExecuted(uint256 _index) {
        require(!proposals[_index].executed, "Purposal already executed");
        _;
    }

    modifier notConfirmed(uint256 _index) {
        require(isConfirmed[_index], "Proposal already confirmed");
        _;
    }
}