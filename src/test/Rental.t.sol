// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {Rental} from "../Rental.sol";
import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {MockERC721} from "./mocks/MockERC721.sol";


import {stdError, stdStorage, StdStorage} from "forge-std/stdlib.sol";

contract RentalTest is DSTestPlus {
    using stdStorage for StdStorage;

    Rental public rental;

    /// @dev Mock NFT
    MockERC721 public mockNft;

    /// @dev Mock Actors
    address public lenderAddress = address(69);
    address public borrowerAddress = address(420);
    
    /// @dev Owned ERC721 Token Id
    uint256 public tokenId = 1337;

    /// @dev Rental Parameters
    uint256 public cachedTimestamp = block.timestamp;
    uint256 public dueDate = cachedTimestamp + 100;
    uint256 public rentalPayment = 10;
    uint256 public collateral = 50;
    uint256 public collateralPayoutPeriod = 40;
    uint256 public nullificationTime = 20;

    function setUp() public {
        // Create MockERC721
        mockNft = new MockERC721("Mock NFT", "MOCK");

        // Mint the lender the owned token id
        mockNft.mint(lenderAddress, tokenId);

        // Give the borrower enough balance
        vm.deal(borrowerAddress, type(uint256).max);

        // Create Rental
        rental = new Rental(
            lenderAddress,
            borrowerAddress,
            address(mockNft),
            tokenId,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod,
            nullificationTime
        );
    }

    /// @notice Test Rental Construction
    function testConstructor() public {
        // Expect Revert when we don't own the token id
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("NonTokenOwner()"))));
        rental = new Rental(
            address(1),
            borrowerAddress,
            address(mockNft),
            tokenId,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod,
            nullificationTime
        );
        vm.stopPrank();

        // Expect Revert if the borrow doesn't have enough balance
        address lender = address(1);
        address borrower = address(2);
        startHoax(lender, lender, type(uint256).max);
        mockNft.mint(lender, tokenId+1);
        vm.deal(borrower, rentalPayment + collateral - 1);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InsufficientValue()"))));
        rental = new Rental(
            lender,
            borrower,
            address(mockNft),
            tokenId+1,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod,
            nullificationTime
        );
        vm.stopPrank();
    }

    /// -------------------------------------------- ///
    /// ---------------- DEPOSIT NFT --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests depositing an NFT into the Rental Contract
    function testDepositNFT() public {
        // Expect Revert when we don't send from the lender address
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.depositNft();
        vm.stopPrank();

        // Expect Revert if the lender doesn't own the token
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.transferFrom(lenderAddress, address(1), tokenId);
        vm.expectRevert("WRONG_FROM");
        rental.depositNft();
        vm.stopPrank();

        // Transfer the token back to the lender
        startHoax(address(1), address(1), type(uint256).max);
        mockNft.transferFrom(address(1), lenderAddress, tokenId);
        vm.stopPrank();

        // The Rental can't transfer if we don't approve it
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.depositNft();
        vm.stopPrank();

        // Rental should not have any eth deposited at this point
        assert(rental.ethIsDeposited() == false);

        // The Lender Can Deposit
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The rental should not have began since we didn't deposit eth
        assert(rental.nftIsDeposited() == true);
        assert(rental.rentalStartTime() == 0);
        assert(rental.collectedCollateral() == 0);

        // We can't redeposit now even if we get the token back somehow
        startHoax(address(rental), address(rental), type(uint256).max);
        mockNft.transferFrom(address(rental), lenderAddress, tokenId);
        vm.stopPrank();
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("AlreadyDeposited()"))));
        rental.depositNft();
        vm.stopPrank();
    }

    /// @notice Tests depositing the NFT into the contract after the borrower deposits eth
    function testDepositETHthenNFT() public {
        // Rental should not have any eth or nft deposited at this point
        assert(rental.ethIsDeposited() == false);
        assert(rental.nftIsDeposited() == false);

        // The Borrower can deposit eth
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // Eth should be deposited
        assert(rental.ethIsDeposited() == true);
        assert(rental.nftIsDeposited() == false);
        assert(rental.rentalStartTime() == 0);
        assert(rental.collectedCollateral() == 0);

        // The Lender Can Deposit
        startHoax(lenderAddress, lenderAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The rental should now begin!
        assert(rental.ethIsDeposited() == true);
        assert(rental.nftIsDeposited() == true);

        assert(mockNft.ownerOf(tokenId) == borrowerAddress);
        assert(lenderAddress.balance == rentalPayment);

        assert(rental.rentalStartTime() == block.timestamp);
    }

    /// -------------------------------------------- ///
    /// ---------------- DEPOSIT ETH --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests depositing ETH into the Rental Contract
    function testDepositETH() public {
        // Expect Revert when we don't send from the borrower address
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.depositEth();
        vm.stopPrank();

        // Expect Revert if not enough eth is sent as a value
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InsufficientValue()"))));
        rental.depositEth();
        vm.stopPrank();

        // Rental should not have any eth deposited at this point
        assert(rental.ethIsDeposited() == false);

        // The Borrower can deposit eth
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // The rental should not have began since the lender hasn't deposited the nft
        assert(rental.ethIsDeposited() == true);
        assert(rental.nftIsDeposited() == false);
        assert(rental.rentalStartTime() == 0);

        // We can't redeposit
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("AlreadyDeposited()"))));
        rental.depositEth();
        vm.stopPrank();
    }

    /// @notice Tests depositing ETH into the Rental Contract after the NFT is deposited
    function testDepositNFTandETH() public {
        // Rental should not have any eth or nft deposited at this point
        assert(rental.ethIsDeposited() == false);
        assert(rental.nftIsDeposited() == false);

        // The Lender Can Deposit
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The nft should be deposited
        assert(rental.nftIsDeposited() == true);

        // Set the lender's balance to 0 to realize the eth transferred from the contract
        vm.deal(lenderAddress, 0);

        // The Borrower can deposit eth
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // The rental should now begin!
        assert(rental.ethIsDeposited() == true);
        assert(rental.nftIsDeposited() == true);

        assert(mockNft.ownerOf(tokenId) == borrowerAddress);
        assert(lenderAddress.balance == rentalPayment);

        assert(rental.rentalStartTime() == block.timestamp);
    }

    /// -------------------------------------------- ///
    /// ---------------- WITHDRAW NFT -------------- ///
    /// -------------------------------------------- ///

    /// @notice Test Withdrawing NFT
    function testWithdrawNft() public {
        uint256 fullPayment = rentalPayment + collateral;

        // Can't withdraw if the nft hasn't been deposited
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawNft();
        vm.stopPrank();

        // The Lender deposits
        startHoax(lenderAddress, lenderAddress, fullPayment);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // Can't withdraw if not the lender
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.withdrawNft();
        vm.stopPrank();

        // The Lender doesn't own the NFT here
        assert(mockNft.ownerOf(tokenId) == address(rental));
    
        // The lender can withdraw the NFT
        startHoax(lenderAddress, lenderAddress, 0);
        rental.withdrawNft();
        vm.stopPrank();

        // The Lender should now own the Token
        assert(mockNft.ownerOf(tokenId) == lenderAddress);
    }

    /// -------------------------------------------- ///
    /// ---------------- WITHDRAW ETH -------------- ///
    /// -------------------------------------------- ///

    /// @notice Test Withdrawing ETH
    function testWithdrawETH() public {
        uint256 fullPayment = rentalPayment + collateral;

        // Can't withdraw if the eth hasn't been deposited
        startHoax(borrowerAddress, borrowerAddress, fullPayment);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawEth();
        vm.stopPrank();

        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, fullPayment);
        rental.depositEth{value: fullPayment}();
        vm.stopPrank();

        // Can't withdraw if not the borrower
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.withdrawEth();
        vm.stopPrank();

        // Set both to have no eth
        vm.deal(borrowerAddress, 0);
    
        // The borrower can withdraw the full contract balance
        startHoax(borrowerAddress, borrowerAddress, 0);
        rental.withdrawEth();
        vm.stopPrank();

        // The borrower should have their full deposit returned
        assert(borrowerAddress.balance == fullPayment);
    }

    /// -------------------------------------------- ///
    /// ----------------- RETURN NFT --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests returning the NFT on time
    function testReturnNFT() public {
        // The Lender deposits
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();


        // A non-owner of the erc721 token id shouldn't be able to transfer
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert("WRONG_FROM");
        rental.returnNft();
        vm.stopPrank();

        // Can't transfer without approval
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.returnNft();
        vm.stopPrank();

        // The borrower should own the NFT now
        assert(mockNft.ownerOf(tokenId) == borrowerAddress);
    
        // The owner should be able to return to the lender
        startHoax(borrowerAddress, borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft();
        assert(borrowerAddress.balance == collateral);
        assert(mockNft.ownerOf(tokenId) == lenderAddress);
        vm.stopPrank();
    }

    /// @notice Tests returning the NFT late
    function testReturnNFTLate() public {
        // The Lender deposits
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // A non-owner of the erc721 token id shouldn't be able to transfer
        startHoax(address(1), address(1), type(uint256).max);
        vm.expectRevert("WRONG_FROM");
        rental.returnNft();
        vm.stopPrank();

        // Can't transfer without approval
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.returnNft();
        vm.stopPrank();

        // The borrower should own the NFT now
        assert(mockNft.ownerOf(tokenId) == borrowerAddress);

        // Jump to between the dueDate and full collateral payout
        vm.warp(dueDate + collateralPayoutPeriod / 2);
    
        // Set the lender to have no eth
        vm.deal(lenderAddress, 0);

        // The owner should be able to return to the lender with a decreased collateral return
        startHoax(borrowerAddress, borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft();
        assert(borrowerAddress.balance == collateral / 2);
        assert(lenderAddress.balance == collateral / 2);
        assert(mockNft.ownerOf(tokenId) == lenderAddress);
        vm.stopPrank();
    }

    /// @notice Tests unable to return NFT since past collateral payout period
    function testReturnNFTFail() public {
        // The Lender deposits
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // The borrower should own the NFT now
        assert(mockNft.ownerOf(tokenId) == borrowerAddress);

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set the lender to have no eth
        vm.deal(lenderAddress, 0);
    
        // The borrower can't return the nft now that it's past the payout period
        // Realistically, this wouldn't be called by the borrower since it just transfers the NFT back to the lender
        startHoax(borrowerAddress, borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft();
        assert(borrowerAddress.balance == 0);
        assert(mockNft.ownerOf(tokenId) == lenderAddress);
        assert(lenderAddress.balance == collateral);
        vm.stopPrank();
    }

    /// -------------------------------------------- ///
    /// ------------- WITHDRAW COLLATERAL ---------- ///
    /// -------------------------------------------- ///

    /// @notice Test withdrawing collateral
    function testWithdrawCollateral() public {
        // The Lender deposits
        startHoax(lenderAddress, lenderAddress, type(uint256).max);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft();
        vm.stopPrank();

        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, type(uint256).max);
        rental.depositEth{value: rentalPayment + collateral}();
        vm.stopPrank();

        // Can't withdraw collateral before the dueDate
        startHoax(lenderAddress, lenderAddress, 0);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawCollateral();
        vm.stopPrank();

        // The borrower should own the NFT now
        assert(mockNft.ownerOf(tokenId) == borrowerAddress);

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set both to have no eth
        vm.deal(lenderAddress, 0);
        vm.deal(borrowerAddress, 0);
    
        // The lender can withdraw the collateral
        startHoax(lenderAddress, lenderAddress, 0);
        rental.withdrawCollateral();
        assert(borrowerAddress.balance == 0);
        assert(mockNft.ownerOf(tokenId) == borrowerAddress);
        assert(lenderAddress.balance == collateral);
        vm.stopPrank();
    }

    /// @notice Test the borrower can withdraw the balance if the lender never deposits
    function testWithdrawCollateralNoLender() public {
        uint256 fullPayment = rentalPayment + collateral;
        // The Borrower deposits
        startHoax(borrowerAddress, borrowerAddress, fullPayment);
        rental.depositEth{value: fullPayment}();
        vm.stopPrank();

        // Can't withdraw collateral before the dueDate
        startHoax(lenderAddress, lenderAddress, 0);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawCollateral();
        vm.stopPrank();

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set both to have no eth
        vm.deal(lenderAddress, 0);
        vm.deal(borrowerAddress, 0);
    
        // The borrower can withdraw the full contract balance
        startHoax(borrowerAddress, borrowerAddress, 0);
        rental.withdrawCollateral();
        assert(borrowerAddress.balance == fullPayment);
        vm.stopPrank();
    }
}
