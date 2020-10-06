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

    mapping(address => mapping(uint[2] => uint)) bids;
    mapping(address => StatusProclaim) madedProclaims;
    mapping(address => uint) proclaims;
    mapping(address => StatusWithdraw) madedWithdraws;
    address[] addressMadeProclaim;
    uint[2] totalContributions;

    enum Stages {
        AcceptingBids,
        RevealWinner,
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

    // This is the current stage.
    Stages public stage = Stages.AcceptingBids;

    uint public creationTime = block.timestamp;
    string[2] public candidates;

    modifier atStage(Stages _stage) {
        require(
            stage == _stage,
            "Function cannot be called at this time."
        );
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

    function nextStage() internal {
        stage = Stages(uint(stage) + 1);
    }

    // This modifier goes to the next stage
    // after the function is done.
    modifier transitionNext()
    {
        _;
        nextStage();
    }

    // Perform timed transitions. Be sure to mention
    // this modifier first, otherwise the guards
    // will not take the new stage into account.
    modifier timedTransitions() {
        if (stage == Stages.AcceptingBlindedBids &&
                    block.timestamp >= creationTime + 10 days)
            nextStage();
        if (stage == Stages.RevealBids &&
                block.timestamp >= creationTime + 12 days)
            nextStage();
        // The other stages transition by transaction
        _;
    }


    modifier goodCandidate(candidate) {
        require (candidate == 0 || candidate == 1);
        _;
    }

    /// This function creates new signboard for participants
    /// @param cand1 the first candidate
    /// @param cand2 the second candidate
    /// Example: cand1 = Trump, cand2 = Bayden. Then signboard = Trump vs Bayden
    /// @dev After creation signboard we start new votes, so need to start stage
    function createDebate (
        string memory cand1,
        string memory cand2
        )
    public onlyOwner {
        signboard = cand1 + " vs " + cand2;
        candidates.push(cand1);
        candidates.push(cand2);
        stage = Stages.AcceptingBids;
    }
    
    
    constructor() public {

    }

    receive () external payable {}

    fallback () external {}

    // Order of the modifiers matters here!
    function makeBid(uint candidate)
        public
        payable
        timedTransitions
        atStage(Stages.AcceptingBids)
        goodCandidate(candidate)
    {
        // Need to prevent a lot of meaningless txs
        require (msg.value >= 1 ether);
        bids[msg.sender][candidate] += msg.value;
        totalContributions[candidate] += msg.value;
    }
    
    function proclaimWinner(uint winner)
        public
        timedTransitions
        atStage(Stages.RevealWinner)
        goodCandidate(winner)
    {
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
    uint[2] ethSavedOpinion;
    // ethChangedOpinion[0] is bidded eth of persons that bidded for 0 candidate
    // and then proclaimed 1 candidate as winner
    uint[2] ethChangedOpinion;
    // ethLazyOpinion[0] is bidded eth of persons that bidded for 0 candidate
    // and then nobody proclaimed
    uint[2] ethLazyOpinion;
    uint public winner;

    /// This function calculate a winner after proclaiming phase
    /// It's some kind of metric in the space of bids and responses
    /// We have also to add to winners  bids of dishonest users who lied about winner
    function calculateWinner() public {
        for (uint i = 0; i < addressMadeProclaim.length; i++) {
            // Made a bid for candidate 0 and proclaimed him
            if (bids[addressMadeProclaim[i]][0] > 0 && proclaims[addressMadeProclaim[i]] == 0)
                ethSavedOpinion[0] += bids[addressMadeProclaim[i]][1];
            // Made a bid for candidate 0 and proclaimed candidate 1 as winner
            else if (bids[addressMadeProclaim[i]][0] > 0 && proclaims[addressMadeProclaim[i]] == 0)
                ethChangedOpinion[0] += bids[addressMadeProclaim[i]][1];
            // Another 'if' clause because ome can bid for both candidates simultaneously
            // Made a bid for candidate 1 and proclaimed him
            if (bids[addressMadeProclaim[i]][1] > 0 && proclaims[addressMadeProclaim[i]] == 1)
                ethSavedOpinion[1] += bids[addressMadeProclaim[i]][1];
            // Made a bid for candidate 1 and proclaimed candidate 0 as winner
            else if (bids[addressMadeProclaim[i]][1] > 0 && proclaims[addressMadeProclaim[i]] == 0)
                ethChangedOpinion[1] += bids[addressMadeProclaim[i]][1];
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
        sharePerHonestWinners = ethForHonestWinners / ethSavedOpinion[winner];
        sharePerLazyWinners = ethForLazyWinners / ethLazyOpinion[winner];
    }
    
    /// Only honest bidders and lazy winners that bidded for winner can 
    /// take their prize
    function withdrawWin()
        public
        atStage(Stages.Finished)
        notWithdrawn
    {
        require(bids[msg.sender][winner] > 0, "You didn't do a bid for winner");
        // made a payment for lazy winner
        if (madedProclaims[msg.sender] == StatusProclaim.NoProclaim) {
            msg.sender.transfer(bids[msg.sender][winner] * sharePerLazyWinners);
        } else {
            require(proclaims[msg.sender] == winner, "You lied about winner");
            // made a payment for honest winner
            msg.sender.transfer(bids[msg.sender][winner] * sharePerHonestWinners);
        }
    }

    /// Only those bidders that bidded for loser and 
    /// proclaimed right winner can return half of bid
    function withdrawLose()
        public
        atStage(Stages.Finished)
        notWithdrawn
    {
        require(bids[msg.sender][1 - winner] > 0, "You didn't do a bid for loser");
        require(
            madedProclaims[msg.sender] == StatusProclaim.DidProclaim,
            "You didn't proclaim any winner"
        );
        require(madedProclaims[msg.sender] == winner, "You lied about winner");
        msg.sender.transfer(bids[msg.sender][1 - winner] / 2);
    }

}
