// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SeatbeltVault
/// @notice A prepaid vault for an AI agent. The agent can only spend within
///         limits the owner sets. Rule violations do NOT revert: they are
///         recorded, and enough of them freeze the vault automatically.
/// @dev    Testnet prototype, unaudited. Native MON only.
contract SeatbeltVault {
    // ---------------------------------------------------------------- errors
    error NotOwner();
    error NotAgent();
    error IsFrozen();
    error Reentrancy();
    error TransferFailed();
    error BadConfig();

    // ---------------------------------------------------------------- events
    event Deposited(address indexed from, uint256 amount);
    event Spent(address indexed to, uint256 amount, uint256 spentInWindow);
    event Denied(address indexed to, uint256 amount, uint8 reason, uint256 deniedCount);
    event VaultFrozen(bool automatic);
    event VaultUnfrozen();
    event AllowlistSet(address indexed account, bool allowed);
    event LimitsSet(uint256 budgetPerWindow, uint256 perTxCap);
    event Withdrawn(uint256 amount);

    // Denial reason codes
    uint8 public constant DENY_NOT_ALLOWED = 1;
    uint8 public constant DENY_OVER_CAP = 2;
    uint8 public constant DENY_OVER_BUDGET = 3;
    uint8 public constant DENY_INSUFFICIENT_BALANCE = 4;

    // ----------------------------------------------------------------- state
    address public immutable owner;
    address public immutable agent;
    uint256 public immutable windowLength; // seconds
    uint256 public immutable maxDenials; // denials per window before auto-freeze

    uint256 public budgetPerWindow;
    uint256 public perTxCap;

    uint256 public windowStart;
    uint256 public spentInWindow;
    uint256 public deniedCount;
    bool public frozen;

    mapping(address => bool) public allowed;

    bool private _locked;

    // ------------------------------------------------------------- modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ----------------------------------------------------------- constructor
    constructor(address _agent, uint256 _budgetPerWindow, uint256 _perTxCap, uint256 _windowLength, uint256 _maxDenials)
        payable {
        if (
            _agent == address(0) || _budgetPerWindow == 0 || _perTxCap == 0 || _perTxCap > _budgetPerWindow
                || _windowLength == 0 || _maxDenials == 0
        ) revert BadConfig();

        owner = msg.sender;
        agent = _agent;
        budgetPerWindow = _budgetPerWindow;
        perTxCap = _perTxCap;
        windowLength = _windowLength;
        maxDenials = _maxDenials;
        windowStart = block.timestamp;

        if (msg.value > 0) emit Deposited(msg.sender, msg.value);
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ------------------------------------------------------------ agent side
    /// @notice The agent's only power. Returns true if paid, false if denied.
    function spend(address payable to, uint256 amount) external nonReentrant returns (bool) {
        if (msg.sender != agent) revert NotAgent();
        if (frozen) revert IsFrozen();

        _rollWindow();

        if (!allowed[to]) return _deny(to, amount, DENY_NOT_ALLOWED);
        if (amount > perTxCap) return _deny(to, amount, DENY_OVER_CAP);
        if (spentInWindow + amount > budgetPerWindow) return _deny(to, amount, DENY_OVER_BUDGET);
        if (amount > address(this).balance) return _deny(to, amount, DENY_INSUFFICIENT_BALANCE);

        spentInWindow += amount; // effects before interaction
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Spent(to, amount, spentInWindow);
        return true;
    }

    // ------------------------------------------------------------ owner side
    function setAllowed(address account, bool isAllowed) external onlyOwner {
        allowed[account] = isAllowed;
        emit AllowlistSet(account, isAllowed);
    }

    function setLimits(uint256 _budgetPerWindow, uint256 _perTxCap) external onlyOwner {
        if (_budgetPerWindow == 0 || _perTxCap == 0 || _perTxCap > _budgetPerWindow) revert BadConfig();
        budgetPerWindow = _budgetPerWindow;
        perTxCap = _perTxCap;
        emit LimitsSet(_budgetPerWindow, _perTxCap);
    }

    function freeze() external onlyOwner {
        frozen = true;
        emit VaultFrozen(false);
    }

    function unfreeze() external onlyOwner {
        frozen = false;
        deniedCount = 0;
        emit VaultUnfrozen();
    }

    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        (bool ok,) = payable(owner).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(amount);
    }

    // ----------------------------------------------------------------- views
    /// @notice Most the agent can spend in a single window (capped by balance).
    /// @dev    Across a window boundary the worst case is up to 2x this value
    ///         (spend at the end of one window, then again at the start of the next).
    function maxLossPerWindow() external view returns (uint256) {
        uint256 bal = address(this).balance;
        return budgetPerWindow < bal ? budgetPerWindow : bal;
    }

    function remainingBudget() external view returns (uint256) {
        if (block.timestamp >= windowStart + windowLength) return budgetPerWindow;
        return budgetPerWindow - spentInWindow;
    }

    // -------------------------------------------------------------- internal
    function _rollWindow() internal {
        if (block.timestamp >= windowStart + windowLength) {
            windowStart = block.timestamp;
            spentInWindow = 0;
            deniedCount = 0;
        }
    }

    function _deny(address to, uint256 amount, uint8 reason) internal returns (bool) {
        deniedCount += 1;
        emit Denied(to, amount, reason, deniedCount);
        if (deniedCount >= maxDenials) {
            frozen = true;
            emit VaultFrozen(true);
        }
        return false;
    }
}
