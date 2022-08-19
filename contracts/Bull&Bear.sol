// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// This import includes functions from both ./KeeperBase.sol and
// ./interfaces/KeeperCompatibleInterface.sol
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// Chainlink Imports
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Dev imports
import "hardhat/console.sol";


contract BullOrBear is ERC721, ERC721Enumerable, ERC721URIStorage, KeeperCompatibleInterface, Ownable, VRFConsumerBaseV2 {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;
    AggregatorV3Interface public pricefeed;

    // implement fulfillRandomWords() as per the VRF documentation
    VRFCoordinatorV2Interface public COORDINATOR;
    uint256[] public s_randomWords;
    uint256 public s_requestId;
    uint32 public callbackGasLimit = 500000; // set higher as fulfillRandomWords is doing a LOT of heavy lifting.
    uint64 public s_subscriptionId; //private id chainlink vrf
    bytes32 keyhash =  0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15; 
    // keyhash, see for Goerli https://docs.chain.link/docs/vrf-contracts/#goerli-testnet
    
    /**
    * Use an interval in seconds and a timestamp to slow execution of Upkeep
    */
    uint public /* immutable */ interval; 
    uint public lastTimeStamp;
    int256 public currentPrice;

    // track the current market trend (hint: use an enum like enum MarketTrend{BULL, BEAR})...
    enum MarketTrend{BULL, BEAR} // Create Enum
    MarketTrend public currentMarketTrend = MarketTrend.BULL; 
    
    // IPFS URIs for the dynamic nft graphics/metadata connected to my IPFS Companion node for bull and bear.
    // Uploaded the contents of the /ipfs folder from my own node for development and production.
    string[] bullUrisIpfs = [
        "https://ipfs.io/ipfs/QmPS5QH9bJArAqDR1Er2iTDTwwEVbPWwhHepodbnHVLSPp?filename=gamer_bull.json.url",
        "https://ipfs.io/ipfs/QmRhmyvrKKKAEd8KZHrLVV2DQQNvgPx5BaZYvT7ZVeUhn1?filename=party_bull.json.url",
        "https://ipfs.io/ipfs/QmVvntPWLF1JK1JJv5QNcvmJxDH32n5hEpkLBXkt1KpVNu?filename=simple_bull.json.url"
    ];
    string[] bearUrisIpfs = [
        "https://ipfs.io/ipfs/QmQ3eKjKtEBjueBThSt1wPrxf2vakkka8iMqsBhafjmKKz?filename=beanie_bear.json.url",
        "https://ipfs.io/ipfs/Qme5bgAtGEdrV3nef1KuQA2qmJHebxckE9yVpXiqphZ2nj?filename=coolio_bear.json.url",
        "https://ipfs.io/ipfs/QmakMeC7q7WYamw7t487DsoG2x6mdRDYrN5gGz7YvicbVN?filename=simple_bear.json.url"
    ];

    event TokensUpdated(string marketTrend);

// ETH/USD Price Feed Contract Address on https://goerli.etherscan.io/address/0x2ca8e0c643bde4c2e08ab1fa0da3401adad7734d
    // Setup VRF. Goerli VRF Coordinator 0x2ca8e0c643bde4c2e08ab1fa0da3401adad7734d
    // https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161
    constructor(uint updateInterval, address _pricefeed, address _vrfCoordinator) ERC721("BullOrBear", "BOB") VRFConsumerBaseV2(_vrfCoordinator) {
        // Set the keeper update interval
        interval = updateInterval; 
        lastTimeStamp = block.timestamp;  //  seconds since unix epoch

        pricefeed = AggregatorV3Interface(_pricefeed); // To pass in the mock
        // set the price for the chosen currency pair.
        currentPrice = getLatestPrice();
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);  
    }

    function safeMint(address to) public  {
        // Current counter value will be the minted token's token ID.
        uint256 tokenId = _tokenIdCounter.current();

        // Increment it so next time it's correct when we call .current()
        _tokenIdCounter.increment();

        // Mint the token
        _safeMint(to, tokenId);

        // Default to a bull NFT on token minting.
        string memory defaultUri = bullUrisIpfs[0];
        _setTokenURI(tokenId, defaultUri);

        console.log("DONE!!! minted token ", tokenId, " and assigned token url: ", defaultUri);
    }
    // Ignore errors for now performData
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory /* performData */) {
         upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
    }

    // update performUpkeep so that it tracks the latest market trend based on the getLatestPrice() 
    // and if there is a price change, it calls another function (eg requestRandomnessForNFTUris()) 
    // that initiates the process of calling a Chainlink VRF V2 Coordinator for a random number. 
    // Modified to handle VRF.
    function performUpkeep(bytes calldata /* performData */ ) external override {
        //We highly recommend revalidating the upkeep in the performUpkeep function
        if ((block.timestamp - lastTimeStamp) > interval ) {
            lastTimeStamp = block.timestamp;         
            int latestPrice =  getLatestPrice(); 
        
            if (latestPrice == currentPrice) {
                console.log("NO CHANGE -> returning!");
                return;
            }

            if (latestPrice < currentPrice) {
                // bear
                currentMarketTrend = MarketTrend.BEAR;
            } else {
                // bull
                currentMarketTrend = MarketTrend.BULL;
            }

            // Initiate the VRF calls to get a random number (word)
            // that will then be used to to choose one of the URIs 
            // that gets applied to all minted tokens.
            requestRandomnessForNFTUris();
            // update currentPrice
            currentPrice = latestPrice;
        } else {
            console.log(
                " INTERVAL NOT UP!"
            );
            return;
        }
    }

    function getLatestPrice() public view returns (int256) {
         (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = pricefeed.latestRoundData();

        return price; //  example price returned 3034715771688
    }

    // below initiates the process of calling a Chainlink VRF V2 Coordinator for a random number...
    function requestRandomnessForNFTUris() internal {
        require(s_subscriptionId != 0, "Subscription ID not set"); 

        // If subscription is not set and funded this will revert.
        s_requestId = COORDINATOR.requestRandomWords(
            keyhash,
            s_subscriptionId, // See https://vrf.chain.link/
            3, //minimum confirmations before response
            callbackGasLimit,
            1 // `numWords` : number of random values we want. Max number for rinkeby is 500 (https://docs.chain.link/docs/vrf-contracts/#rinkeby-testnet)
        );

        console.log("Request ID: ", s_requestId);

        // requestId looks like uint256: 80023009725525451140349768621743705773526822376835636211719588211198618496446
    }

    // This is the callback that the VRF coordinator sends the random values to.
  function fulfillRandomWords(
    uint256, /* requestId */
    uint256[] memory randomWords
    ) internal override {
        s_randomWords = randomWords;
        console.log("---fulfillRandomWords---");

        string[] memory urisForTrend = currentMarketTrend == MarketTrend.BULL ? bullUrisIpfs : bearUrisIpfs;
        uint256 idx = randomWords[0] % urisForTrend.length;

        for (uint i = 0; i < _tokenIdCounter.current(); i++) {
            _setTokenURI(i, urisForTrend[idx]);
        }

    string memory trend = currentMarketTrend == MarketTrend.BULL ? "bullish market!" : "bearish market!";
    
    emit TokensUpdated(trend);
  }


  function setPriceFeed(address newFeed) public onlyOwner {
      pricefeed = AggregatorV3Interface(newFeed);
  }
  function setInterval(uint256 newInterval) public onlyOwner {
      interval = newInterval;
  }

  // For VRF Subscription Manager
  function setSubscriptionId(uint64 _id) public onlyOwner {
      s_subscriptionId = _id;
  }


  function setCallbackGasLimit(uint32 maxGas) public onlyOwner {
      callbackGasLimit = maxGas;
  }

  function setVrfCoodinator(address _address) public onlyOwner {
    COORDINATOR = VRFCoordinatorV2Interface(_address);
  }
    


    // Helpers
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        // No longer used as not being called when using VRF, as we're now using enums.
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
    // This will update all the NFTs in the contract to Bear or Bull.
    function updateAllTokenUris(string memory trend) internal {
      // The logic from this has been moved up to fulfill random words.
    }



    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
