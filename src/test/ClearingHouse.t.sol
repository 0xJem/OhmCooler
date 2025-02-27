// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UserFactory} from "test/lib/UserFactory.sol";

import {MockOhm} from "test/mocks/MockOhm.sol";
import {MockStaking} from "test/mocks/MockStaking.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solmate/test/utils/mocks/MockERC4626.sol";

import {Permissions, Keycode, fromKeycode, toKeycode} from "olympus-v3/Kernel.sol";
import {RolesAdmin, Kernel, Actions} from "olympus-v3/policies/RolesAdmin.sol";
import {OlympusRoles, ROLESv1} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {OlympusMinter, MINTRv1} from "olympus-v3/modules/MINTR/OlympusMinter.sol";
import {OlympusTreasury, TRSRYv1} from "olympus-v3/modules/TRSRY/OlympusTreasury.sol";
//import {Actions} from "olympus-v3/Kernel.sol";

import {ClearingHouse, Cooler, CoolerFactory, CoolerCallback} from "src/ClearingHouse.sol";
//import {Cooler, Loan, Request} from "src/Cooler.sol";

// Tests for ClearingHouse
//
// ClearingHouse Setup and Permissions.
// [X] configureDependencies
// [X] requestPermissions
//
// ClearingHouse Functions
// [X] rebalance
//     [X] can't rebalance faster than the funding cadence.
//     [X] Treasury approvals for the clearing house are correct.
//     [X] if necessary, sends excess DSR funds back to the Treasury.
//     [X] if a rebalances are missed, can execute several rebalances if FUND_CADENCE allows it.
// [X] sweepIntoDSR
//     [X] excess DAI is deposited into DSR.
// [X] defund
//     [X] only "cooler_overseer" can call.
//     [X] cannot defund gOHM.
//     [X] sends input ERC20 token back to the Treasury.
// [X] lendToCooler
//     [X] only lend to coolers issued by coolerFactory.
//     [X] only collateral = gOHM + only debt = DAI.
//     [x] user and cooler new gOHM balances are correct.
//     [x] user and cooler new DAI balances are correct.
// [X] rollLoan
//     [X] roll by adding more collateral.
//     [X] roll by paying the interest.
//     [X] user and cooler new gOHM balances are correct.
// [X] onRepay
//     [X] only coolers issued by coolerFactory can call.
//     [X] receivables are updated.
// [ ] onDefault
//     [X] only coolers issued by coolerFactory can call.
//     [X] receivables are updated.
//     [X] OHM supply is properly burnt.


/// @dev Although there is sDAI in the treasury, the sDAI will be equal to
///      DAI values everytime we convert between them. This is because no external
///      DAI is being added to the sDAI vault, so the exchange rate is 1:1. This
///      does not cause any issues with our testing.
contract ClearingHouseTest is Test {
    MockOhm internal ohm;
    MockERC20 internal gohm;
    MockERC20 internal dai;
    MockERC4626 internal sdai;

    Kernel public kernel;
    OlympusRoles internal ROLES;
    OlympusMinter internal MINTR;
    OlympusTreasury internal TRSRY;
    RolesAdmin internal rolesAdmin;
    ClearingHouse internal clearinghouse;
    CoolerFactory internal factory;
    Cooler internal testCooler;

    address internal user;
    address internal others;
    address internal overseer;
    uint256 internal initialSDai;

    function setUp() public {
        address[] memory users = (new UserFactory()).create(3);
        user = users[0];
        others = users[1];
        overseer = users[2];

        MockStaking staking = new MockStaking();
        factory = new CoolerFactory();

        ohm = new MockOhm("olympus", "OHM", 9);
        gohm = new MockERC20("olympus", "gOHM", 18);
        dai = new MockERC20("dai", "DAI", 18);
        sdai = new MockERC4626(dai, "sDai", "sDAI");

        kernel = new Kernel(); // this contract will be the executor

        TRSRY = new OlympusTreasury(kernel);
        MINTR = new OlympusMinter(kernel, address(ohm));
        ROLES = new OlympusRoles(kernel);

        clearinghouse = new ClearingHouse(
            address(gohm),
            address(staking),
            address(sdai),
            address(factory),
            address(kernel)
        );
        rolesAdmin = new RolesAdmin(kernel);

        kernel.executeAction(Actions.InstallModule, address(TRSRY));
        kernel.executeAction(Actions.InstallModule, address(MINTR));
        kernel.executeAction(Actions.InstallModule, address(ROLES));

        kernel.executeAction(Actions.ActivatePolicy, address(clearinghouse));
        kernel.executeAction(Actions.ActivatePolicy, address(rolesAdmin));

        /// Configure access control
        rolesAdmin.grantRole("cooler_overseer", overseer);

        // Setup clearinghouse initial conditions
        uint mintAmount = 200_000_000e18;  // Init treasury with 200 million
        dai.mint(address(TRSRY), mintAmount);
        // Deposit all reserves into the DSR
        vm.startPrank(address(TRSRY));
        dai.approve(address(sdai), mintAmount);
        sdai.deposit(mintAmount, address(TRSRY));
        vm.stopPrank();

        // Initial rebalance to fund the clearinghouse
        clearinghouse.rebalance();

        testCooler = Cooler(factory.generateCooler(gohm, dai));

        gohm.mint(overseer, mintAmount);

        // Skip 1 week ahead to allow rebalances
        skip(1 weeks);

        // Initial funding of clearinghouse is equal to FUND_AMOUNT
        assertEq(sdai.maxWithdraw(address(clearinghouse)), clearinghouse.FUND_AMOUNT());
        
        // Fund others so that TRSRY is not the only with sDAI shares
        dai.mint(others, mintAmount * 33);
        vm.startPrank(others);
        dai.approve(address(sdai), mintAmount * 33);
        sdai.deposit(mintAmount * 33, others);
        vm.stopPrank();
    }

    // --- HELPER FUNCTIONS ----------------------------------------------

    function _fundUser(uint256 gohmAmount_) internal {
        // Mint gOHM
        gohm.mint(user, gohmAmount_);
        // Approve clearinghouse
        vm.prank(user);
        gohm.approve(address(clearinghouse), gohmAmount_);
    }

    function _createLoanForUser(uint256 loanAmount_) internal returns (Cooler cooler, uint256 gohmNeeded, uint256 loanID) {
        // Create the Cooler
        vm.prank(user);
        cooler = Cooler(factory.generateCooler(gohm, dai));

        // Ensure user has enough collateral
        gohmNeeded = cooler.collateralFor(loanAmount_, clearinghouse.LOAN_TO_COLLATERAL());
        _fundUser(gohmNeeded);

        vm.prank(user);
        loanID = clearinghouse.lendToCooler(cooler, loanAmount_);
    }

    function _skip(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        if (block.timestamp >= clearinghouse.fundTime()) {
            clearinghouse.rebalance();
        }
    }

    // --- SETUP, DEPENDENCIES, AND PERMISSIONS --------------------------
    
    function test_configureDependencies() public {
        Keycode[] memory expectedDeps = new Keycode[](3);
        expectedDeps[0] = toKeycode("TRSRY");
        expectedDeps[1] = toKeycode("MINTR");
        expectedDeps[2] = toKeycode("ROLES");

        Keycode[] memory deps = clearinghouse.configureDependencies();
        // Check: configured dependencies storage
        assertEq(deps.length, expectedDeps.length);
        assertEq(fromKeycode(deps[0]), fromKeycode(expectedDeps[0]));
        assertEq(fromKeycode(deps[1]), fromKeycode(expectedDeps[1]));
        assertEq(fromKeycode(deps[2]), fromKeycode(expectedDeps[2]));
    }

    function test_requestPermissions() public {
        Permissions[] memory expectedPerms = new Permissions[](5);
        Keycode TRSRY_KEYCODE = toKeycode("TRSRY");
        Keycode MINTR_KEYCODE = toKeycode("MINTR");
        expectedPerms[0] = Permissions(TRSRY_KEYCODE, TRSRY.setDebt.selector);
        expectedPerms[1] = Permissions(TRSRY_KEYCODE, TRSRY.repayDebt.selector);
        expectedPerms[2] = Permissions(TRSRY_KEYCODE, TRSRY.incurDebt.selector);
        expectedPerms[3] = Permissions(TRSRY_KEYCODE, TRSRY.increaseDebtorApproval.selector);
        expectedPerms[4] = Permissions(MINTR_KEYCODE, MINTR.burnOhm.selector);
        
        Permissions[] memory perms = clearinghouse.requestPermissions();
        // Check: permission storage
        assertEq(perms.length, expectedPerms.length);
        for (uint256 i = 0; i < perms.length; i++) {
            assertEq(fromKeycode(perms[i].keycode), fromKeycode(expectedPerms[i].keycode));
            assertEq(perms[i].funcSelector, expectedPerms[i].funcSelector);
        }
    }

    // --- LEND TO COOLER ------------------------------------------------

    function testRevert_lendToCooler_NotFromFactory() public {
        CoolerFactory maliciousFactory = new CoolerFactory();
        Cooler maliciousCooler = Cooler(maliciousFactory.generateCooler(gohm, dai));
        // Coolers not created by the CoolerFactory could be malicious.
        vm.prank(address(maliciousCooler));
        vm.expectRevert(CoolerCallback.OnlyFromFactory.selector);
        clearinghouse.lendToCooler(maliciousCooler, 1e18);
    }

    function testRevert_lendToCooler_NotGohmDai() public {
        MockERC20 wagmi = new MockERC20("wagmi", "WAGMI", 18);
        MockERC20 ngmi = new MockERC20("ngmi", "NGMI", 18);

        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler1 = Cooler(factory.generateCooler(wagmi, ngmi));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lendToCooler(badCooler1, 1e18);
        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler2 = Cooler(factory.generateCooler(gohm, ngmi));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lendToCooler(badCooler2, 1e18);
        // Clearinghouse only accepts gOHM-DAI
        Cooler badCooler3 = Cooler(factory.generateCooler(wagmi, dai));
        vm.expectRevert(ClearingHouse.BadEscrow.selector);
        clearinghouse.lendToCooler(badCooler3, 1e18);
    }
    
    function testFuzz_lendToCooler(uint256 loanAmount_) public {
        // Loan amount cannot exceed Clearinghouse funding
        loanAmount_ = bound(loanAmount_, 0, clearinghouse.FUND_AMOUNT());

        (Cooler cooler, uint256 gohmNeeded, uint256 loanID) = _createLoanForUser(loanAmount_);

        // Check: balances
        assertEq(gohm.balanceOf(address(cooler)), gohmNeeded);
        assertEq(dai.balanceOf(address(user)), loanAmount_);
        assertEq(dai.balanceOf(address(cooler)), 0);
        // Check: clearinghouse storage
        assertEq(clearinghouse.receivables(), clearinghouse.debtForCollateral(gohmNeeded));
        assertApproxEqAbs(clearinghouse.receivables(), cooler.getLoan(loanID).amount, 1e4);
    }

    // --- ROLL LOAN -----------------------------------------------------

    function testFuzz_rollLoan_pledgingExtraCollateral(uint256 loanAmount_) public {
        // Loan amount cannot exceed Clearinghouse funding
        loanAmount_ = bound(loanAmount_, 0, clearinghouse.FUND_AMOUNT());

        (Cooler cooler, uint256 gohmNeeded, uint256 loanID) = _createLoanForUser(loanAmount_);
        Cooler.Loan memory initLoan = cooler.getLoan(loanID);

        // Move forward to half duration of the loan
        _skip(clearinghouse.DURATION()/2);

        // Cache DAI balance and extra interest to be paid
        uint256 initDaiUser = dai.balanceOf(user);
        uint256 interestExtra = cooler.interestFor(initLoan.amount, clearinghouse.INTEREST_RATE(), clearinghouse.DURATION());
        // Ensure user has enough collateral to roll the loan
        uint256 gohmExtra = cooler.newCollateralFor(loanID);
        _fundUser(gohmExtra);
        // Roll loan
        vm.prank(user);
        clearinghouse.rollLoan(cooler, loanID);

        Cooler.Loan memory newLoan = cooler.getLoan(loanID);

        // Check: balances
        assertEq(gohm.balanceOf(address(cooler)), gohmNeeded + gohmExtra);
        assertEq(dai.balanceOf(user), initDaiUser);
        // Check: cooler storage
        assertEq(newLoan.amount, initLoan.amount + interestExtra);
        assertEq(newLoan.unclaimed, initLoan.unclaimed);
        assertEq(newLoan.collateral, initLoan.collateral + gohmExtra);
        assertEq(newLoan.expiry, initLoan.expiry + initLoan.request.duration);
    }

    function testFuzz_rollLoan_repayingInterest(uint256 loanAmount_) public {
        // Loan amount cannot exceed Clearinghouse funding
        // Loan amount must exceed 0.0001 gOHM, so that repaying the interest decollaterizes de loan.
        loanAmount_ = bound(loanAmount_, 1e14, clearinghouse.FUND_AMOUNT());

        (Cooler cooler, uint256 gohmNeeded, uint256 loanID) = _createLoanForUser(loanAmount_);
        Cooler.Loan memory initLoan = cooler.getLoan(loanID);

        // Move forward to half duration of the loan
        _skip(clearinghouse.DURATION()/2);

        vm.startPrank(user);
        // Cache DAI balance and extra interest to be paid in the future
        uint256 initDaiUser = dai.balanceOf(user);
        // Repay the interest of the loan (interest = owed debt - borrowed amount)
        uint256 repay = initLoan.amount - initLoan.request.amount;
        dai.approve(address(cooler), repay);
        uint256 decollateralized = cooler.repayLoan(loanID, repay);
        // Roll loan
        gohm.approve(address(clearinghouse), decollateralized);
        clearinghouse.rollLoan(cooler, loanID);
        vm.stopPrank();

        Cooler.Loan memory newLoan = cooler.getLoan(loanID);

        // Check: balances
        assertEq(gohm.balanceOf(address(cooler)), gohmNeeded);
        assertEq(dai.balanceOf(user), initDaiUser - repay);
        // Check: cooler storage
        assertEq(newLoan.amount, initLoan.amount);
        assertEq(newLoan.unclaimed, initLoan.unclaimed);
        assertEq(newLoan.collateral, initLoan.collateral);
        assertEq(newLoan.expiry, initLoan.expiry + initLoan.request.duration);
    }

    // --- REBALANCE TREASURY --------------------------------------------

    function test_rebalance_pullFunds() public {
        uint256 oneMillion = 1e24;
        uint256 sdaiOneMillion = sdai.previewWithdraw(1e24);
        uint256 daiInitCH = sdai.maxWithdraw(address(clearinghouse));
        uint256 sdaiInitCH = sdai.balanceOf(address(clearinghouse));

        // Burn 1 mil from clearinghouse to simulate assets being lent
        vm.prank(address(clearinghouse));
        sdai.withdraw(oneMillion, address(0x0), address(clearinghouse));

        assertEq(sdai.maxWithdraw(address(clearinghouse)), daiInitCH - oneMillion, "DAI balance CH");
        assertEq(sdai.balanceOf(address(clearinghouse)), sdaiInitCH - sdaiOneMillion, "sDAI balance CH");
        // Test if clearinghouse pulls in 1 mil DAI from treasury
        uint256 daiInitTRSRY = sdai.maxWithdraw(address(TRSRY));
        uint256 sdaiInitTRSRY = sdai.balanceOf(address(TRSRY));

        clearinghouse.rebalance();

        assertEq(daiInitTRSRY - oneMillion, sdai.maxWithdraw(address(TRSRY)), "DAI balance TRSRY");
        assertEq(sdaiInitTRSRY - sdaiOneMillion, sdai.balanceOf(address(TRSRY)), "sDAI balance TRSRY");
        assertEq(clearinghouse.FUND_AMOUNT(), sdai.maxWithdraw(address(clearinghouse)), "FUND_AMOUNT");
    }

    function test_rebalance_returnFunds() public {
        uint256 oneMillion = 1e24;
        uint256 sdaiOneMillion = sdai.previewWithdraw(1e24);
        uint256 daiInitCH = sdai.maxWithdraw(address(clearinghouse));
        uint256 sdaiInitCH = sdai.balanceOf(address(clearinghouse));

        // Mint 1 million to clearinghouse and sweep to simulate assets being repaid
        dai.mint(address(clearinghouse), oneMillion);
        clearinghouse.sweepIntoDSR();

        assertEq(sdai.maxWithdraw(address(clearinghouse)), daiInitCH + oneMillion, "DAI balance CH");
        assertEq(sdai.balanceOf(address(clearinghouse)), sdaiInitCH + sdaiOneMillion, "sDAI balance CH");

        uint256 daiInitTRSRY = sdai.maxWithdraw(address(TRSRY));
        uint256 sdaiInitTRSRY = sdai.balanceOf(address(TRSRY));

        clearinghouse.rebalance();

        assertEq(daiInitTRSRY + oneMillion, sdai.maxWithdraw(address(TRSRY)), "DAI balance TRSRY");
        assertEq(sdaiInitTRSRY + sdaiOneMillion, sdai.balanceOf(address(TRSRY)), "sDAI balance TRSRY");
        assertEq(clearinghouse.FUND_AMOUNT(), sdai.maxWithdraw(address(clearinghouse)), "FUND_AMOUNT");
    }

    function testRevert_rebalance_early() public {
        bool canRebalance;
        // Rebalance to be up-to-date with the FUND_CADENCE.
        canRebalance = clearinghouse.rebalance();
        assertEq(canRebalance, true);
        // Second rebalance is ahead of time, and will not happen.
        canRebalance = clearinghouse.rebalance();
        assertEq(canRebalance, false);
    }

    // Should be able to rebalance multiple times if past due
    function test_rebalance_pastDue() public {
        // Already skipped 1 week ahead in setup. Do once more and call rebalance twice.
        skip(2 weeks);
        for(uint i; i < 3; i++) {
            clearinghouse.rebalance();
        }
    }

    // --- SWEEP INTO DSR ------------------------------------------------

    function test_sweepIntoDSR() public {
        uint256 sdaiBal = sdai.balanceOf(address(clearinghouse));

        // Mint 1 million to clearinghouse and sweep to simulate assets being repaid
        dai.mint(address(clearinghouse), 1e24);
        clearinghouse.sweepIntoDSR();

        assertEq(sdai.balanceOf(address(clearinghouse)), sdaiBal + 1e24);
    }

    // --- DEFUND CLEARINGHOUSE ------------------------------------------

    function test_defund() public {
        uint256 sdaiTrsryBal = sdai.balanceOf(address(TRSRY));
        vm.prank(overseer);
        clearinghouse.defund(sdai, 1e24);
        assertEq(sdai.balanceOf(address(TRSRY)), sdaiTrsryBal + 1e24);
    }

    function testRevert_defund_gohm() public {
        vm.prank(overseer);
        vm.expectRevert(ClearingHouse.OnlyBurnable.selector);
        clearinghouse.defund(gohm, 1e24);
    }

    // --- CALLBACKS: ON LOAN REPAYMENT ----------------------------------

    function testFuzz_onRepay(uint256 loanAmount_) public {
        // Loan amount cannot exceed Clearinghouse funding
        // Loan amount must exceed 0.0001 gOHM, so that repaying the interest decollaterizes de loan.
        loanAmount_ = bound(loanAmount_, 1e14, clearinghouse.FUND_AMOUNT());

        (Cooler cooler,, uint256 loanID) = _createLoanForUser(loanAmount_);
        Cooler.Loan memory initLoan = cooler.getLoan(loanID);

        // Move forward to half duration of the loan
        _skip(clearinghouse.DURATION()/2);

        vm.startPrank(user);
        // Cache clearinghouse receivables
        uint256 initReceivables = clearinghouse.receivables();
        // Repay the interest of the loan (interest = owed debt - borrowed amount)
        uint256 repay = initLoan.amount - initLoan.request.amount;
        dai.approve(address(cooler), repay);
        cooler.repayLoan(loanID, repay);

        // Check: clearinghouse storage
        assertEq(clearinghouse.receivables(), initReceivables - repay);
        assertApproxEqAbs(clearinghouse.receivables(), cooler.getLoan(loanID).amount, 1e4);
    }

    function testRevert_onRepay_notFromFactory() public {
        CoolerFactory maliciousFactory = new CoolerFactory();
        Cooler maliciousCooler = Cooler(maliciousFactory.generateCooler(gohm, dai));
        // Coolers not created by the CoolerFactory could be malicious.
        vm.prank(address(maliciousCooler));
        vm.expectRevert(CoolerCallback.OnlyFromFactory.selector);
        clearinghouse.onRepay(0, 1e18);
    }

    // --- CLAIM DEFAULTED ----------------------------------

    function testFuzz_claimDefaulted(uint256 loanAmount_) public {
        // Loan amount cannot exceed Clearinghouse funding
        // Loan amount must exceed 0.0001 gOHM, so that repaying the interest decollaterizes de loan.
        uint256 loanAmount1_ = bound(loanAmount_, 1e14, clearinghouse.FUND_AMOUNT() / 3);
        uint256 loanAmount2_ = 2 * loanAmount1_;

        (Cooler cooler1, uint256 gohmNeeded1, uint256 loanID1) = _createLoanForUser(loanAmount1_);
        (Cooler cooler2, uint256 gohmNeeded2, uint256 loanID2) = _createLoanForUser(loanAmount2_);
        Cooler.Loan memory initLoan1 = cooler1.getLoan(loanID1);
        Cooler.Loan memory initLoan2 = cooler2.getLoan(loanID2);

        // Move forward after both loans have ended
        _skip(clearinghouse.DURATION() + 1);

        // Cache clearinghouse receivables and TRSRY debt
        uint256 initReceivables = clearinghouse.receivables();
        uint256 initDebt = TRSRY.reserveDebt(sdai, address(clearinghouse));

        // Simulate unstaking outcome after defaults
        ohm.mint(address(clearinghouse), gohmNeeded1 + gohmNeeded2);

        uint256[] memory ids = new uint256[](2);
        address[] memory coolers = new address[](2);
        ids[0] = loanID1;
        ids[1] = loanID2;
        coolers[0] = address(cooler1);
        coolers[1] = address(cooler2);        
        // Claim defaulted loans
        vm.prank(overseer);
        clearinghouse.claimDefaulted(coolers, ids);

        uint256 daiReceivables = initLoan1.amount + initLoan2.amount;
        uint256 sdaiDebt = sdai.previewDeposit(daiReceivables - clearinghouse.interestFromDebt(daiReceivables));
        // Check: clearinghouse storage
        assertEq(clearinghouse.receivables(), initReceivables > daiReceivables ? initReceivables - daiReceivables : 0);
        // Check: TRSRY storage
        assertApproxEqAbs(TRSRY.reserveDebt(sdai, address(clearinghouse)), initDebt > sdaiDebt ? initDebt - sdaiDebt : 0, 1e4);
        // After defaults the clearing house keeps the collateral (which is supposed to be unstaked and burned)
        assertEq(gohm.balanceOf(address(clearinghouse)), gohmNeeded1 + gohmNeeded2, "gOHM balance");
        // Check: OHM supply = 0 (only minted before burning)
        assertEq(ohm.totalSupply(), 0);
    }

    function testRevert_claimDefaulted_inputLengthDiscrepancy() public {
        uint256[] memory ids = new uint256[](2);
        address[] memory coolers = new address[](1);
        ids[0] = 12345;
        ids[1] = 67890;
        coolers[0] = others;  
        // Claim defaulted loans
        vm.prank(overseer);
        // Both input arrays must have the same length
        vm.expectRevert(ClearingHouse.LengthDiscrepancy.selector);
        clearinghouse.claimDefaulted(coolers, ids);
    }
}