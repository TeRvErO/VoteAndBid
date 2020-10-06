// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.7.0;

// Owned.sol
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


/**
 * The Bet contract does this and that...
 */
contract Bet is Owned {
    // Signboard of debates
    string public signboard;

    enum Stages {
        Initial,
        AcceptingBids,
        RevealWinner,
        CalculateWinner,
        Withdrawals,
        Finished
    }

    enum StatusProclaim {
        NoProclaim,
        DidProclaim
    }

    enum StatusWithdraw {
        NoWithdraw,
        DidWithdraw
    }

    mapping(address => uint) public bidsForCand0;
    mapping(address => uint) public bidsForCand1;
    mapping(address => StatusProclaim) public madedProclaims;
    mapping(address => uint) public proclaims;
    mapping(address => StatusWithdraw) public madedWithdraws;
    address[] public addressMadeProclaim;
    uint[2] public totalContributions;

    Stages public stage = Stages.Initial;

    //uint public creationTime = block.timestamp;
    string[2] public candidates;

    uint endTimeBid;
    uint endTimeProclamation;
    uint endTimeFinal;

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
        require(
            madedWithdraws[msg.sender] == StatusWithdraw.NoWithdraw,
            "You have already made a withdraw."
        );
        madedWithdraws[msg.sender] = StatusWithdraw.DidWithdraw;
        _;
    }

    // This modifier goes to the next stage
    // after the function is done.
    modifier transitionNext()
    {
        _;
        nextStage();
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

    // Order of the modifiers matters here!
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
        if (candidate == 0)
            bidsForCand0[msg.sender] += msg.value;
        else
            bidsForCand1[msg.sender] += msg.value;
        totalContributions[candidate] += msg.value;
    }
    
    function proclaimWinner(uint winner)
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
        require(madedProclaims[msg.sender] == StatusProclaim.NoProclaim, "You have already proclaimed a winner");
        madedProclaims[msg.sender] = StatusProclaim.DidProclaim;
        proclaims[msg.sender] = winner;
        addressMadeProclaim.push(msg.sender);
    }

    // a_0 = ethForCand0Win0;
    // b_0 = ethForCand0Win1;
    // a_1 = ethForCand1Win1;
    // b_1 = ethForCand1Win0;
    // c_0 = ethForCand0Lazy = totalContributions[0] - a_0 - b_0;
    // c_1 = ethForCand1Lazy = totalContributions[1] - a_1 - b_1;
    // totalContributionFor0 = a_0 + b_0 + c_0;
    // totalContributionFor1 = a_1 + b_1 + c_1;

    // ethSavedOpinion[0] is bidded eth of persons that bidded for 0 candidate
    // and then proclaimed him as winner
    uint[2] public ethSavedOpinion;
    // ethChangedOpinion[0] is bidded eth of persons that bidded for 0 candidate
    // and then proclaimed 1 candidate as winner
    uint[2] public ethChangedOpinion;
    // ethLazyOpinion[0] is bidded eth of persons that bidded for 0 candidate
    // and then nobody proclaimed
    uint[2] public ethLazyOpinion;
    uint public winner;

    uint public sharePerHonestWinners;
    uint public sharePerLazyWinners;
    uint public ethForHonestLosers;
    uint public ethForHonestWinners;
    uint public ethForLazyWinners;

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
            if (bidsForCand0[addressMadeProclaim[i]] > 0 && proclaims[addressMadeProclaim[i]] == 0)
                ethSavedOpinion[0] += bidsForCand0[addressMadeProclaim[i]];
            // Made a bid for candidate 0 and proclaimed candidate 1 as winner
            else if (bidsForCand0[addressMadeProclaim[i]] > 0 && proclaims[addressMadeProclaim[i]] == 1)
                ethChangedOpinion[0] += bidsForCand0[addressMadeProclaim[i]];
            // Another 'if' clause because one can bid for both candidates simultaneously
            // Made a bid for candidate 1 and proclaimed him
            if (bidsForCand1[addressMadeProclaim[i]] > 0 && proclaims[addressMadeProclaim[i]] == 1)
                ethSavedOpinion[1] += bidsForCand1[addressMadeProclaim[i]];
            // Made a bid for candidate 1 and proclaimed candidate 0 as winner
            else if (bidsForCand1[addressMadeProclaim[i]] > 0 && proclaims[addressMadeProclaim[i]] == 0)
                ethChangedOpinion[1] += bidsForCand1[addressMadeProclaim[i]];
        }
        ethLazyOpinion[0] = totalContributions[0] - ethSavedOpinion[0] - ethChangedOpinion[0];
        ethLazyOpinion[1] = totalContributions[1] - ethSavedOpinion[1] - ethChangedOpinion[1];
        winner = (ethSavedOpinion[0] + ethChangedOpinion[1] > ethSavedOpinion[1] + ethChangedOpinion[0]) ? 0 : 1;
        //q = totalContributions[0] / totalContributions[1];
        // winner = (a_0 / q + b_1 * q > a_1 * q + b_0 / q) ? 0 : 1;
        ethForHonestLosers = ethChangedOpinion[1 - winner] / 2;
        // this is reward pool for winners. It's consist of bids of persons:
        // - that bidded for nonwinner and after didn't change their opinion
        // - that bidded for winner but then lied about real winner
        // - that bidded for nonwinner but then admit a winner
        ethForHonestWinners = ethSavedOpinion[1 - winner] + ethChangedOpinion[winner] + ethForHonestLosers;
        ethForLazyWinners = ethLazyOpinion[1 - winner];
        sharePerHonestWinners = (ethSavedOpinion[winner] != 0) ? ethForHonestWinners / ethSavedOpinion[winner] : 0;
        sharePerLazyWinners = (ethLazyOpinion[winner] != 0) ? ethForLazyWinners / ethLazyOpinion[winner] : 0;
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
        uint amount;
        amount = (winner == 0) ? bidsForCand0[msg.sender] : bidsForCand1[msg.sender];
        require(amount > 0, "You didn't do a bid for winner");
        // made a payment for lazy winner
        if (madedProclaims[msg.sender] == StatusProclaim.NoProclaim) {
            msg.sender.transfer(amount * sharePerLazyWinners);
        } else {
            require(proclaims[msg.sender] == winner, "You lied about winner");
            // made a payment for honest winner
            msg.sender.transfer(amount * sharePerHonestWinners);
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
        uint amount;
        amount = (winner == 0) ? bidsForCand1[msg.sender] : bidsForCand0[msg.sender];
        require(amount > 0, "You didn't do a bid for loser");
        require(
            madedProclaims[msg.sender] == StatusProclaim.DidProclaim,
            "You didn't proclaim any winner"
        );
        require(proclaims[msg.sender] == winner, "You lied about winner");
        msg.sender.transfer(amount / 2);
    }

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
