// SPDX-License-Identifier: UNLICENSED
// 1TK proprietary candidate (original modifications only).
// Historical MV1 MIT grant and third-party OpenZeppelin MIT terms remain effective.
// CANDIDATE ONLY: no Mainnet deployment without independent security, license & integration signoff.
pragma solidity ^0.8.37;

/*
    OneToken - 1TK
    ---------------
    Release candidate, OZ 5.7.0, Solidity 0.8.37, EVM Prague; no production approval.

    Features:
    - ERC20 token.
    - Citizen status system.
    - Citizen minting.
    - Genesis citizen minting with 1-year unlock time.
    - Citizen ID.
    - Genesis Mirror minting to a dedicated GenesisLiquidityVault.
    - Mirror tokens do NOT receive citizenStatus, citizenId, or genesisUnlockTime.
    - Managed exit cancellation only through VerificationManager.
    - Final punitive burn state STATUS_BURNED.
    - Optional self-burn for free-market / buyback burns.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract OneToken is ERC20, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 8_400_000_000 * 1e18;
    uint256 public constant ONE_TOKEN = 1e18;

    uint256 public constant MAX_GENESIS = 1000;
    uint256 public constant GENESIS_LOCK_DURATION = 365 days;

    uint8 public constant STATUS_NONE = 0;
    uint8 public constant STATUS_ACTIVE = 1;
    uint8 public constant STATUS_EXIT_REVIEW = 2;
    uint8 public constant STATUS_EXITED = 3;
    uint8 public constant STATUS_BANNED = 4;
    uint8 public constant STATUS_BURNED = 5;

    address public minter;
    address public verificationManager;

    // Genesis Mirror liquidity vault.
    address public genesisLiquidityVault;

    // Monitoring events allow independent audit of roles and status changes.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    event VerificationManagerUpdated(address indexed previousManager, address indexed newManager);
    event GenesisLiquidityVaultUpdated(address indexed previousVault, address indexed newVault);
    event CitizenStatusChanged(address indexed citizen, uint8 previousStatus, uint8 newStatus);

    mapping(address => uint8) public citizenStatus;

    // Citizen number for every real citizen.
    // 0 means no citizenId assigned.
    mapping(address => uint256) public citizenId;

    // First citizenId will be 1.
    uint256 public nextCitizenId = 1;

    // Genesis lock data.
    // 0 means not Genesis.
    // > 0 means Genesis, and the value is the unlock timestamp.
    mapping(address => uint256) public genesisUnlockTime;

    // Number of real Genesis citizens minted.
    uint256 public genesisMinted;

    // Number of Mirror 1TK tokens minted to the GenesisLiquidityVault.
    // This is counted as whole 1TK units, not wei.
    // Example: genesisMirrorMinted = 10 means 10 Mirror tokens.
    uint256 public genesisMirrorMinted;

    constructor(address initialOwner) ERC20("OneToken", "1TK") Ownable(initialOwner) {
        require(initialOwner != address(0), "Zero address not allowed");
    }

    // Permanent admin controls are required for citizenship and recovery.
    // An accidental renounce would make the project unmanageable forever.
    function renounceOwnership() public view override onlyOwner {
        revert("Renounce disabled");
    }

    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "Zero address not allowed");
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    function setVerificationManager(address _verificationManager) external onlyOwner {
        require(_verificationManager != address(0), "Zero address not allowed");
        emit VerificationManagerUpdated(verificationManager, _verificationManager);
        verificationManager = _verificationManager;
    }

    function setGenesisLiquidityVault(address vault) external onlyOwner {
        require(vault != address(0), "Zero address not allowed");
        require(citizenStatus[vault] == STATUS_NONE, "Vault cannot be a registered citizen");
        require(vault.code.length > 0, "Vault must be a deployed contract");
        emit GenesisLiquidityVaultUpdated(genesisLiquidityVault, vault);
        genesisLiquidityVault = vault;
    }

    function mintCitizen(address to) external {
        require(msg.sender == minter, "Only authorized minter can mint");
        require(to != address(0), "Zero address not allowed");
        require(citizenStatus[to] == STATUS_NONE, "Already registered");
        require(to != genesisLiquidityVault, "Vault cannot become citizen");
        require(totalSupply() + ONE_TOKEN <= MAX_SUPPLY, "Max supply reached");

        citizenStatus[to] = STATUS_ACTIVE;
        emit CitizenStatusChanged(to, STATUS_NONE, STATUS_ACTIVE);
        citizenId[to] = nextCitizenId;

        unchecked {
            nextCitizenId++;
        }

        _mint(to, ONE_TOKEN);
    }

    function mintGenesisCitizen(address to) external {
        require(msg.sender == minter, "Only authorized minter can mint");
        require(to != address(0), "Zero address not allowed");
        require(citizenStatus[to] == STATUS_NONE, "Already registered");
        require(to != genesisLiquidityVault, "Vault cannot become citizen");
        require(genesisMinted < MAX_GENESIS, "Genesis limit reached");
        require(totalSupply() + ONE_TOKEN <= MAX_SUPPLY, "Max supply reached");

        citizenStatus[to] = STATUS_ACTIVE;
        emit CitizenStatusChanged(to, STATUS_NONE, STATUS_ACTIVE);
        citizenId[to] = nextCitizenId;
        genesisUnlockTime[to] = block.timestamp + GENESIS_LOCK_DURATION;

        unchecked {
            nextCitizenId++;
            genesisMinted++;
        }

        _mint(to, ONE_TOKEN);
    }

    /*
        Mint Genesis Mirror tokens to the dedicated liquidity vault.

        mirrorCount is counted in whole 1TK tokens, not wei.

        Example:
        - mirrorCount = 1  => mints 1 * 1e18
        - mirrorCount = 10 => mints 10 * 1e18

        Mirror rules:
        - Mirror goes only to genesisLiquidityVault.
        - Mirror cannot exceed the number of real Genesis citizens.
        - Mirror does not receive citizenStatus.
        - Mirror does not receive citizenId.
        - Mirror does not receive genesisUnlockTime.
    */
    function mintGenesisMirrorToVault(uint256 mirrorCount) external onlyOwner {
        require(genesisLiquidityVault != address(0), "Genesis vault not set");
        require(citizenStatus[genesisLiquidityVault] == STATUS_NONE, "Vault cannot be citizen");
        require(mirrorCount > 0, "Zero mirror count");
        require(
            genesisMirrorMinted + mirrorCount <= genesisMinted,
            "Mirror exceeds Genesis"
        );

        uint256 tokenAmount = mirrorCount * ONE_TOKEN;

        require(totalSupply() + tokenAmount <= MAX_SUPPLY, "Max supply reached");

        unchecked {
            genesisMirrorMinted += mirrorCount;
        }

        _mint(genesisLiquidityVault, tokenAmount);
    }

    function availableGenesisMirror() external view returns (uint256) {
        return genesisMinted - genesisMirrorMinted;
    }

    function requestExit() external {
        require(citizenStatus[msg.sender] == STATUS_ACTIVE, "Not an active citizen");

        citizenStatus[msg.sender] = STATUS_EXIT_REVIEW;
        emit CitizenStatusChanged(msg.sender, STATUS_ACTIVE, STATUS_EXIT_REVIEW);
    }

    function cancelExitRequestByManager(address user) external {
        require(msg.sender == verificationManager, "Only verification manager");
        require(citizenStatus[user] == STATUS_EXIT_REVIEW, "Not under exit review");

        citizenStatus[user] = STATUS_ACTIVE;
        emit CitizenStatusChanged(user, STATUS_EXIT_REVIEW, STATUS_ACTIVE);
    }

    function approveExit(address user) external {
        require(msg.sender == verificationManager, "Only verification manager");
        require(citizenStatus[user] == STATUS_EXIT_REVIEW, "Not under exit review");
        // Enforce the Genesis lock at the token layer, not only in the manager.
        require(
            genesisUnlockTime[user] == 0 || block.timestamp >= genesisUnlockTime[user],
            "Genesis locked"
        );

        citizenStatus[user] = STATUS_EXITED;
        emit CitizenStatusChanged(user, STATUS_EXIT_REVIEW, STATUS_EXITED);
    }

    function banCitizen(address user) external {
        require(msg.sender == verificationManager, "Only verification manager");
        require(citizenStatus[user] == STATUS_EXIT_REVIEW, "Not under exit review");

        citizenStatus[user] = STATUS_BANNED;
        emit CitizenStatusChanged(user, STATUS_EXIT_REVIEW, STATUS_BANNED);
    }

    function restoreCitizen(address user, uint8 restoredStatus) external {
        require(msg.sender == verificationManager, "Only verification manager");
        require(citizenStatus[user] == STATUS_BANNED, "Citizen is not banned");
        require(
            restoredStatus == STATUS_ACTIVE || restoredStatus == STATUS_EXITED,
            "Invalid restored status"
        );
        require(balanceOf(user) >= ONE_TOKEN, "No citizen token");
        // Restoring a banned Genesis citizen to EXITED must never bypass the lock.
        if (restoredStatus == STATUS_EXITED) {
            require(
                genesisUnlockTime[user] == 0 || block.timestamp >= genesisUnlockTime[user],
                "Genesis locked"
            );
        }

        citizenStatus[user] = restoredStatus;
        emit CitizenStatusChanged(user, STATUS_BANNED, restoredStatus);
    }

    function burnBannedCitizen(address user) external {
        require(msg.sender == verificationManager, "Only verification manager");
        require(citizenStatus[user] == STATUS_BANNED, "Citizen is not banned");

        uint256 amount = balanceOf(user);
        require(amount > 0, "No token to burn");

        _burn(user, amount);

        citizenStatus[user] = STATUS_BURNED;
        emit CitizenStatusChanged(user, STATUS_BANNED, STATUS_BURNED);
    }

    function burn(uint256 amount) external {
        require(amount > 0, "Zero burn amount");

        uint8 status = citizenStatus[msg.sender];

        require(status != STATUS_ACTIVE, "Active citizen cannot burn");
        require(status != STATUS_EXIT_REVIEW, "Exit request under review");
        require(status != STATUS_BANNED, "Citizen banned");
        require(status != STATUS_BURNED, "Citizen burned");

        _burn(msg.sender, amount);
    }

    function canEndorse(address user) external view returns (bool) {
        return citizenStatus[user] == STATUS_ACTIVE;
    }

    function isGenesisCitizen(address user) external view returns (bool) {
        return genesisUnlockTime[user] != 0;
    }

    function hasGenesisLockExpired(address user) external view returns (bool) {
        uint256 unlockTime = genesisUnlockTime[user];

        if (unlockTime == 0) {
            return true;
        }

        return block.timestamp >= unlockTime;
    }

    // OZ 4.9.6 also exposes increaseAllowance/decreaseAllowance. Both must
    // enforce the same status policy, otherwise approve() can be bypassed.
    function _requireApprovalEligible(address account) internal view {
        uint8 status = citizenStatus[account];

        require(status != STATUS_ACTIVE, "Active citizen cannot approve");
        require(status != STATUS_EXIT_REVIEW, "Exit request under review");
        require(status != STATUS_BANNED, "Citizen banned");
        require(status != STATUS_BURNED, "Citizen burned");
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        // Revoking a pre-citizenship allowance must remain possible at all times.
        // A zero allowance is never a new spending permission.
        if (value != 0) {
            _requireApprovalEligible(msg.sender);
        }
        return super.approve(spender, value);
    }

    // Explicitly retain the legacy external functions omitted from OZ 5.x.
    // No newly granted allowance is permitted for a restricted citizen.
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _requireApprovalEligible(msg.sender);
        _approve(msg.sender, spender, allowance(msg.sender, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        // Reducing an existing allowance never grants new transfer rights.
        uint256 oldAllowance = allowance(msg.sender, spender);
        require(oldAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(msg.sender, spender, oldAllowance - subtractedValue);
        }
        return true;
    }

    // Preserve the MV1 Approval log emitted when a finite allowance is spent.
    // OpenZeppelin 5.x otherwise suppresses this log in transferFrom.
    function _approve(address owner, address spender, uint256 value, bool) internal override {
        super._approve(owner, spender, value, true);
    }

    // OZ 5.x replacement for _beforeTokenTransfer; preserve MV1's transfer-only policy.
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            uint8 fromStatus = citizenStatus[from];
            uint8 toStatus = citizenStatus[to];

            require(fromStatus != STATUS_ACTIVE, "Active citizen cannot transfer");
            require(fromStatus != STATUS_EXIT_REVIEW, "Exit request under review");
            require(fromStatus != STATUS_BANNED, "Citizen banned");
            require(fromStatus != STATUS_BURNED, "Citizen burned");
            require(toStatus != STATUS_ACTIVE && toStatus != STATUS_EXIT_REVIEW && toStatus != STATUS_BANNED && toStatus != STATUS_BURNED, "Recipient restricted");
        }

        super._update(from, to, amount);
    }
}