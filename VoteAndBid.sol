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

    event Bid(address bidder, uint candidate);
    event Proclamation(address bidder, uint winner);
    event CalculatedWinner(uint winner);
    
    enum Stages {
        Initial,
        AcceptingBids,
        RevealWinner,
        CalculateWinner,
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
        // Reward pool for honest losers who proclaimed right winner. 
        // It's returns half of their initial bids
        uint ethForHonestLosers;
        // Reward pool for honest winners. It's consist of bids of persons:
        // - that bidded for nonwinner and after didn't change their opinion
        // - that bidded for winner but then lied about real winner
        // - the half of bid of users who vote for nonwinner but then proclaimed right winner
        uint ethForHonestWinners;
        // Reward pool for lazy winers. It's consist of bids of lazy losers
        uint ethForLazyWinners;
    }

    mapping(address => UserInfo) public users;
    // info about bids and its transhes for each candidate
    TranchesEthOfUsers[2] public bids;
    Rewards public rewards;
    
    Stages public stage;
    // candidates for voting as strings
    string[2] public candidates;
    uint endTimeBid;
    uint endTimeProclamation;
    uint endTimeFinal;

    address[] public addressMadeProclaim;
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

    modifier isGoodCandidate(uint candidate) {
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
        startTimeBid = block.timestamp;
        endTimeBid = startTimeBid + _durationTimeBids;
        endTimeProclamation = endTimeBid + _durationTimeProclamation;
        endTimeFinal = endTimeProclamation + 1 days;
        stage = Stages.AcceptingBids;
    }
    
    constructor() {}

    receive () external payable {}

    fallback () external {}

    // Function to make a bid for candidate in current voting
    function makeBid(uint candidate)
        public
        payable
        isGoodCandidate(candidate)
    {
        require(stage == Stages.AcceptingBids && block.timestamp <= endTimeBid, "Ended bid phase");
        // Need to prevent a lot of meaningless txs
        require(msg.value > 0 ether, "Bid must be higher");

        if (users[msg.sender].amountBid != 0)
            require(candidate == users[msg.sender].candidate, "You have already made a bid for another candidate");
        users[msg.sender].candidate = candidate;
        users[msg.sender].amountBid += msg.value;
        bids[candidate].totalContributions += msg.value;

        emit Bid(msg.sender, candidate);
    }
    
    // Function to proclaim winner after bidding phase
    function proclaimWinner(uint proclaimedWinner)
        public
        isGoodCandidate(winner)
        onlyAfter(endTimeBid)
        onlyBefore(endTimeProclamation)
    {
        if (stage == Stages.AcceptingBids)
            stage = Stages.RevealWinner;

        require(stage == Stages.RevealWinner, "Ended proclamation phase");
        require(users[msg.sender].amountBid > 0, "Only users who made a bid can proclaim a winner");
        require(!users[msg.sender].statusProclaim, "You have already proclaimed a winner");

        users[msg.sender].statusProclaim = true;
        users[msg.sender].winner = proclaimedWinner;
        addressMadeProclaim.push(msg.sender);

        emit Proclamation(msg.sender, proclaimedWinner);
    }

    /// This function calculate a winner after proclaiming phase
    /// It's some kind of metric in the space of bids and responses
    /// We have to also add to winners bids of dishonest users who lied about winner
    function calculateWinner()
        public
        atStage(Stages.RevealWinner)
        onlyAfter(endTimeProclamation)
        onlyBefore(endTimeFinal)
    {

        stage = Stages.CalculateWinner;
        require(stage == Stages.CalculateWinner, "Has already calculate winner");
        for (uint i = 0; i < addressMadeProclaim.length; i++) {
            // Made a bid for candidate 0 and proclaimed him
            address addr = addressMadeProclaim[i];
            if (users[addr].candidate == 0 && users[addr].winner == 0)
                bids[0].ethSavedOpinion += users[addr].amountBid;
            // Made a bid for candidate 0 and proclaimed candidate 1 as winner
            else if (users[addr].candidate == 0 && users[addr].winner == 1)
                bids[0].ethChangedOpinion += users[addr].amountBid;
            // Made a bid for candidate 1 and proclaimed him
            else if (users[addr].candidate == 1 && users[addr].winner == 1)
                bids[1].ethSavedOpinion += users[addr].amountBid;
            // Made a bid for candidate 1 and proclaimed candidate 0 as winner
            else if (users[addr].candidate == 1 && users[addr].winner == 0)
                bids[1].ethChangedOpinion += users[addr].amountBid;
        }
        for (uint i; i < candidates.length; i++)
            bids[i].ethLazyOpinion = bids[i].totalContributions -
                bids[i].ethSavedOpinion - bids[i].ethChangedOpinion;

        winner = (bids[0].ethSavedOpinion + bids[1].ethChangedOpinion > bids[1].ethSavedOpinion + bids[0].ethChangedOpinion) ? 0 : 1;
        //q = totalContributions[0] / totalContributions[1];
        // winner = (a_0 / q + b_1 * q > a_1 * q + b_0 / q) ? 0 : 1;
        rewards.ethForHonestLosers = bids[1 - winner].ethChangedOpinion / 2;
        rewards.ethForHonestWinners = bids[1 - winner].ethSavedOpinion +
            bids[winner].ethChangedOpinion + rewards.ethForHonestLosers;
        rewards.ethForLazyWinners = bids[1 - winner].ethLazyOpinion;

        sharePerHonestWinners = (bids[winner].ethSavedOpinion != 0) ?
            rewards.ethForHonestWinners / bids[winner].ethSavedOpinion : 0;
        sharePerLazyWinners = (bids[winner].ethLazyOpinion != 0) ?
            rewards.ethForLazyWinners / bids[winner].ethLazyOpinion : 0;
        stage = Stages.Withdrawals;

        emit CalculatedWinner(winner);
    }
    
    /// Only honest active (who proclaimed winner) bidders and lazy users 
    /// that bidded for winner can take their prize
    function withdrawWin()
        public
        startedVote
        atStage(Stages.Withdrawals)
        notWithdrawn
    {
        require(
            users[msg.sender].amountBid > 0 && users[msg.sender].candidate == winner, 
            "You didn't do a bid for winner"
        );
        // made a payment for lazy winner
        if (!users[msg.sender].statusProclaim) {
            msg.sender.transfer(users[msg.sender].amountBid * sharePerLazyWinners);
        } else {
            require(users[msg.sender].winner == winner, "You lied about winner");
            // made a payment for honest winner
            msg.sender.transfer(users[msg.sender].amountBid * sharePerHonestWinners);
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
            users[msg.sender].amountBid > 0 && users[msg.sender].candidate != winner,
            "You didn't do a bid for loser"
        );
        require(users[msg.sender].statusProclaim, "You didn't proclaim any winner");
        require(users[msg.sender].winner == winner, "You lied about winner");
        msg.sender.transfer(users[msg.sender].amountBid / 2);
    }

    /// Owner can take eth after 7 days of final completion of voting
    function withdrawForgotten()
        public
        startedVote
        onlyOwner
        onlyAfter(endTimeFinal + 7 days)
    {
        stage = Stages.Finished;
        msg.sender.transfer(address(this).balance);
    }

    // Function to proclaim winner after bidding phase
    function proclaimWinner(uint vote, uint winner)
        public
        isGoodCandidate(winner)
        onlyAfter(endTimeBid)
        onlyBefore(endTimeProclamation)
    {
        if (stage == Stages.AcceptingBids)
            stage = Stages.RevealWinner;

        require(stage == Stages.RevealWinner, "Ended proclamation phase");
        judges.setWinnerByDelegate(vote, winner);

        emit Proclamation(msg.sender, proclaimedWinner);
    }

    function calculateWinner(uint vote)
        public
        atStage(Stages.RevealWinner)
        onlyAfter(endTimeProclamation)
        onlyBefore(endTimeFinal)
    {
        stage = Stages.CalculateWinner;
        require(stage == Stages.CalculateWinner, "Has already calculate winner");

        winner = judges.calculateWinner(vote);
        uint totalContributions = bids[0].totalContributions + bids[1].totalContributions;
        rewards[vote].ethForDelegators = totalContributions.div(100);
        rewards[vote].ethForOwner = totalContributions.div(100);
        rewards[vote].ethForWinningVotes = totalContributions.mul(98).div(100);

        sharePerDelegator = rewards[vote].ethForDelegators.div(judges.countHonestDelegators(vote, winner));

        stage = Stages.Withdrawals;

        emit CalculatedWinner(winner);
    }

    /// Only honest active (who proclaimed winner) bidders and lazy users 
    /// that bidded for winner can take their prize
    function withdrawWin(uint vote)
        public
        startedVote
        atStage(Stages.Withdrawals)
        notWithdrawn
    {
        require(
            users[msg.sender].amountBid > 0 && users[msg.sender].candidate == winner, 
            "You didn't do a bid for winner"
        );
        msg.sender.transfer(users[msg.sender].amountBid.mul(rewards[vote].ethForWinningVotes).div(bids[winner].totalContributions));
    }

    /// Only honest active (who proclaimed winner) bidders and lazy users 
    /// that bidded for winner can take their prize
    function withdrawDelegatorFee(uint vote)
        public
        startedVote
        atStage(Stages.Withdrawals)
        notWithdrawn
    {
        require(judges.isDelegator(), "You are not a judge");
        require(judges.getWinner(vote) == winner, "You lied about winner");
        msg.sender.transfer(rewards[vote].ethForDelegators.div(countHonestDelegators(vote, winner)));
    }
}

contract Judges is Owned {

    event CalculatedWinner(uint vote, address delegator, uint winner);

    uint[] public winners;

    mapping (uint => uint) winners;
    mapping (uint => uint) sumWinnerForVote;
    mapping (address => bool) statusDelegate;
    mapping (uint => mapping(uint => uint)) countSetsDelegators;

    struct DelegateVote {
        bool announcedWinner;
        uint winner;
    }

    struct Winner {
        bool calculated;
        uint winner;
    }

    mapping (uint => mapping(address => DelegateVote)) infoDelegates;
    mapping (uint => Winner) infoWinners;

    constructor() {
        statusDelegate[msg.sender] = true;
    }

    receive () external payable {}

    fallback () external {}

    function setVote(uint _vote) onlyOwner {
        currentVote = _vote;
    }

    function addDelegate(address _delegate) onlyOwner {
        statusDelegate[_delegate] = true;
    }

    function removeDelegate(address _delegate) onlyOwner {
        statusDelegate[_delegate] = false;
    }

    function isDelegator() public {
        return statusDelegate[msg.sender];
    }

    function getWinner(uint vote) onlyDelegators {
        require(infoDelegates[vote][msg.sender].announcedWinner, "You didn't set a winner in this vote");
        return infoDelegates[vote][msg.sender].winner;
    }

    function getReward (uint vote) onlyDelegators {
        require (infoWinners[vote].calculated, "Didn't calculated winner for this vote");
        return (getWinner(vote) == infoWinners[vote].winner);
    }
    
    function countHonestDelegators (uint vote, uint winner) external {
        return countSetsDelegators[vote][winner];
    }

    modifier onlyDelegators {
        require (isDelegator(), "Only for delegators");
        _;
    }  

    /// This function calculate a winner after proclaiming phase
    /// It's some kind of metric in the space of bids and responses
    /// We have to also add to winners bids of dishonest users who lied about winner
    function setWinnerByDelegate(uint vote, uint _winner)
        public
        payable
        onlyDelegators
    {
        require (vote == currentVote, "Current vote is not vote in parameter");
        require(stage == Stages.CalculateWinner, "Has already calculate winner");
        infoDelegates[vote][msg.sender].announcedWinner = true;
        infoDelegates[vote][msg.sender].winner = _winner;
        sumWinnerForVote[vote] += _winner;
        countSetsDelegators[vote][_winner] += 1;

        emit CalculatedWinner(vote, msg.sender, winner);
    }

    function calculateWinner(uint vote)
        public
        returns (uint winner)
    {
        require (vote == currentVote, "Current vote is not vote in parameter");
        require(!infoWinners[vote].calculated, "Already calculated");
        infoWinners[vote].calculated = true;
        if (2 * sumWinnerForVote[vote] > winners.length)
            winner = 1;
        else
            winner = 0;
        infoWinners[vote].winner = winner;
    }
}
