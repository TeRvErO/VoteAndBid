// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.7.0;

contract Owned {

    address public owner;
    uint public creationTime = block.timestamp;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner, "Only owner can do this");
        _;
    }

    modifier onlyBefore(uint _time) {
        require(
            block.timestamp <= _time,
            "Function called too late."
        );
        _;
    }

    modifier onlyAfter(uint _time) {
        require(
            block.timestamp >= _time,
            "Function called too early."
        );
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    /// Erase ownership information.
    /// May only be called 6 weeks after
    /// the contract has been created.
    function freeOwnership()
        public
        onlyOwner
        onlyAfter(creationTime + 6 weeks)
    {
        delete owner;
    }

}

contract VoteAndBid is Owned {
    // Signboard of debates
    string public signboard;

    enum Stages {
        Initial,
        AcceptingBids,
        RevealWinner,
        CalculaiteWnner,
        Withdrawals,
        Finished
    }

    struct UserInfo {
        uint candidate;
        uint amountBid;
        bool statusProclaim;
        uint winner;
        bool statusWithdraw;
    }

    struct TranchesEthOfUsers {
        uint totalContributions;
        // amount of bidded eth of persons that bidded for candidate and
        // then proclaimed him as winner
        uint ethSavedOpinion;
        // amount of bidded eth of persons that bidded for candidate and
        // then proclaimed another candidate as winner
        uint ethChangedOpinion;
        // amount of bidded eth of persons that bidded for candidate and
        // then proclaimed nobody
        uint ethLazyOpinion;
    }

    struct Rewards {
        // this is reward pool for honest losers who proclaimed right winner. 
        // It's returns half of their initial bids:
        uint ethForHonestLosers;
        // this is reward pool for honest winners. It's consist of bids of persons:
        // - that bidded for nonwinner and after didn't change their opinion
        // - that bidded for winner but then lied about real winner
        // - that bidded for nonwinner but then admit a winner
        uint ethForHonestWinners;
        // this is reward pool for lazy winers. It's consist of bids of lazy losers
        uint ethForLazyWinners;
    }

    mapping(address => UserInfo) public users;
    TranchesEthOfUsers[2] public bids;
    Rewards public rewards;
    address[] public addressMadeProclaim;

    Stages public stage = Stages.Initial;

    string[2] public candidates;
    uint endTimeBid;
    uint endTimeProclamation;
    uint endTimeFinal;

    uint public winner;

    uint public sharePerHonestWinners;
    uint public sharePerLazyWinners;

    modifier atStage(Stages _stage) {
        require(
            stage == _stage,
            "Function cannot be called at this time."
        );
        _;
    }

    modifier startedVote() {
        require (stage != Stages.Initial, "Vote didn't started yet");
        _;
    }

    modifier notWithdrawn {
        require(!users[msg.sender].statusWithdraw, "You have already made a withdraw.");
        users[msg.sender].statusWithdraw = true;
        _;
    }

    modifier goodCandidate(uint candidate) {
        require (candidate == 0 || candidate == 1, "Wrong index number of candidate");
        _;
    }

    function nextStage() internal {
        stage = Stages(uint(stage) + 1);
    }

    function append(string memory a, string memory b) public pure returns (string memory s){
        s = string(abi.encodePacked(a, b));
    }

    /// This function creates new signboard for participants
    /// @param cand1 the first candidate
    /// @param cand2 the second candidate
    /// Example: cand1 = Trump, cand2 = Bayden. Then signboard = Trump vs Bayden
    /// @dev After creation signboard we start new votes, so need to start stage
    function createDebate (
        string memory cand1,
        string memory cand2,
        uint _durationTimeBids,
        uint _durationTimeProclamation
    )
        public
        onlyOwner
    {
        uint startTimeBid;
        signboard = append(cand1, append(string(" vs "), cand2));
        candidates[0] = cand1;
        candidates[1] = cand2;
        stage = Stages.AcceptingBids;
        startTimeBid = block.timestamp;
        endTimeBid = startTimeBid + _durationTimeBids;
        endTimeProclamation = endTimeBid + _durationTimeProclamation;
        endTimeFinal = endTimeProclamation + 1 days;
        stage = Stages.AcceptingBids;
    }
    
    constructor() {}

    receive () external payable {}

    fallback () external {}

    function makeBid(uint candidate)
        public
        payable
        startedVote
        atStage(Stages.AcceptingBids)
        goodCandidate(candidate)
    {
        require(stage == Stages.AcceptingBids && block.timestamp <= endTimeBid, "Ended bid phase");
        // Need to prevent a lot of meaningless txs
        //require (msg.value >= 1 ether);
        users[msg.sender].candidate = candidate;
        users[msg.sender].amountBid += msg.value;
        bids[candidate].totalContributions += msg.value;
    }
    
    function proclaimWinner(uint proclaimWinner)
        public
        startedVote
        goodCandidate(winner)
        onlyAfter(endTimeBid)
    {
        if (stage == Stages.AcceptingBids && block.timestamp <= endTimeProclamation)
            stage = Stages.RevealWinner;
        require(
            stage == Stages.RevealWinner && block.timestamp <= endTimeProclamation,
            "Ended proclamation phase"
        );
        require(!users[msg.sender].statusProclaim, "You have already proclaimed a winner");
        users[msg.sender].statusProclaim = true;
        users[msg.sender].winner = proclaimWinner;
        addressMadeProclaim.push(msg.sender);
    }

    /// This function calculate a winner after proclaiming phase
    /// It's some kind of metric in the space of bids and responses
    /// We have also to add to winners  bids of dishonest users who lied about winner
    function calculateWinner()
        public
        startedVote
        onlyAfter(endTimeProclamation)
        onlyBefore(endTimeFinal)
    {
        if (stage == Stages.RevealWinner)
            stage = Stages.CalculateWinner;
        require(stage == Stages.CalculateWinner, "Has already calculate winner");
        for (uint i = 0; i < addressMadeProclaim.length; i++) {
            // Made a bid for candidate 0 and proclaimed him
            address addr = addressMadeProclaim[i];
            if (users[addr].amountBid > 0 && users[addr].candidate == 0 && users[addr].winner == 0)
                bids[0].ethSavedOpinion += users[addr].amountBid;
            // Made a bid for candidate 0 and proclaimed candidate 1 as winner
            else if (users[addr].amountBid > 0 && users[addr].candidate == 0 && users[addr].winner == 1)
                bids[0].ethChangedOpinion += users[addr].amountBid;
            // Another 'if' clause because one can bid for both candidates simultaneously
            // Made a bid for candidate 1 and proclaimed him
            if (users[addr].amountBid > 0 && users[addr].candidate == 1 && users[addr].winner == 1)
                bids[1].ethSavedOpinion += users[addr].amountBid;
            // Made a bid for candidate 1 and proclaimed candidate 0 as winner
            else if (users[addr].amountBid > 0 && users[addr].candidate == 1 && users[addr].winner == 0)
                bids[1].ethChangedOpinion += users[addr].amountBid;
        }
        bids[0].ethLazyOpinion = bids[0].totalContributions -
            bids[0].ethSavedOpinion - bids[0].ethChangedOpinion;
        bids[1].ethLazyOpinion = bids[1].totalContributions -
            bids[1].ethSavedOpinion - bids[1].ethChangedOpinion;
        winner = (bids[0].ethSavedOpinion + bids[1].ethChangedOpinion > bids[1].ethSavedOpinion + bids[0].ethChangedOpinion) ? 0 : 1;
        //q = totalContributions[0] / totalContributions[1];
        // winner = (a_0 / q + b_1 * q > a_1 * q + b_0 / q) ? 0 : 1;
        rewards.ethForHonestLosers = rewards.ethChangedOpinion / 2;
        rewards.ethForHonestWinners = bids[1 - winner].ethSavedOpinion +
            bids[winner].ethChangedOpinion + rewards.ethForHonestLosers;
        rewards.ethForLazyWinners = bids[1 - winner].ethLazyOpinion;

        sharePerHonestWinners = (bids[winner].ethSavedOpinion != 0) ?
            rewards.ethForHonestWinners / bids[winner].ethSavedOpinion : 0;
        sharePerLazyWinners = (bids[winner].ethLazyOpinion != 0) ?
            rewards.ethForLazyWinners / bids[winner].ethLazyOpinion : 0;
        stage = Stages.Withdrawals;
    }
    
    /// Only honest bidders and lazy winners that bidded for winner can 
    /// take their prize
    function withdrawWin()
        public
        startedVote
        atStage(Stages.Withdrawals)
        notWithdrawn
    {
        require(
            users[msg.sender].candidate == winner && users[msg.sender].amountBid > 0, 
            "You didn't do a bid for winner"
        );
        // made a payment for lazy winner
        if (!users[msg.sender].statusProclaim) {
            msg.sender.transfer(users[msg.sender].amountBid * sharePerLazyWinners);
        } else {
            require(users[msg.sender].winner == winner, "You lied about winner");
            // made a payment for honest winner
            msg.sender.transfer(users[msg.sender].amountBid  * sharePerHonestWinners);
        }
    }

    /// Only those bidders that bidded for loser and 
    /// proclaimed right winner can return half of bid
    function withdrawLose()
        public
        startedVote
        atStage(Stages.Withdrawals)
        notWithdrawn
    {
        require(
            users[msg.sender].candidate != winner && users[msg.sender].amountBid > 0,
            "You didn't do a bid for loser"
        );
        require(users[msg.sender].statusProclaim, "You didn't proclaim any winner");
        require(users[msg.sender].winner == winner, "You lied about winner");
        msg.sender.transfer(users[msg.sender].amountBid / 2);
    }

    /// Owner can take eth after 7 days of final completion voting
    function WithdrawForgotten()
        public
        startedVote
        onlyOwner
        onlyAfter(endTimeFinal + 7 days)
    {
        stage = Stages.Finished;
        msg.sender.transfer(address(this).balance);
    }   
}
