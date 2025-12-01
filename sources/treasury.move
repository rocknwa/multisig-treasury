module multisig_treasury::treasury {
    // ------------------------------
    // Imports / module dependencies
    // ------------------------------
    // `use` brings names from other modules into scope.
    // These are standard Sui Move modules for coins, balances, tables, events, and strings.
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::event;
    use std::string::String;

    // ------------------------------
    // Error codes
    // ------------------------------
    // Use numeric constants for assertion failure reasons.
    // These numbers are returned on `assert!` failures to indicate the error.
    const EInvalidThreshold: u64 = 1;
    const EInvalidSigners: u64 = 2;
    const ENotSigner: u64 = 3;
    const EInsufficientSignatures: u64 = 4;
    const ETimeLockNotExpired: u64 = 5;
    const EPolicyViolation: u64 = 6;
    const EProposalNotFound: u64 = 7;
    const EAlreadySigned: u64 = 8;
    const EInvalidAmount: u64 = 9;
    const ESpendingLimitExceeded: u64 = 10;
    const ENotWhitelisted: u64 = 11;
    const EInCooldownPeriod: u64 = 14;
    const EMaxBatchSizeExceeded: u64 = 15;
    const EProposalAlreadyExecuted: u64 = 16;

    // ------------------------------
    // Configuration constants
    // ------------------------------
    // MAX_BATCH_SIZE: maximum number of transactions in one proposal.
    // EMERGENCY_COOLDOWN_PERIOD: milliseconds to wait between emergency operations.
    const MAX_BATCH_SIZE: u64 = 50;
    const EMERGENCY_COOLDOWN_PERIOD: u64 = 86400000; // 24 hours in ms

    // ------------------------------
    // Data structures (core domain objects)
    // ------------------------------

    /// Main treasury object holding funds and global configuration.
    /// `has key, store` means it can be stored as an object on-chain and used as a resource key.
    public struct Treasury has key, store {
        id: UID,                         // Unique object id (opaque resource)
        name: String,                    // Human readable treasury name
        signers: vector<address>,        // Authorized signers' addresses
        threshold: u64,                  // Number of signatures required for normal proposals
        balance_sui: Balance<SUI>,       // On-chain SUI balance (held as Balance<SUI>)
        policy_config: PolicyConfig,     // Spending policies and thresholds
        spending_tracker: SpendingTracker,// Track spends by period & category
        proposal_count: u64,             // Incremental counter for proposals
        emergency_config: EmergencyConfig,// Emergency-specific configuration
        created_at: u64,                 // Timestamp when treasury was created (ms epoch)
    }

    /// Policy configuration struct.
    /// Stores per-category limits, global limits, whitelists, amount/time thresholds.
    public struct PolicyConfig has store {
        spending_limits: Table<String, SpendingLimit>, // category -> SpendingLimit
        global_limit: SpendingLimit,                   // fallback global limit
        whitelisted_addresses: vector<address>,        // recipients allowed if non-empty
        blacklisted_addresses: vector<address>,        // recipients explicitly blocked (unused in this sample)
        category_thresholds: Table<String, u64>,       // category -> number-of-signatures required
        amount_thresholds: vector<AmountThreshold>,    // amount-based signature thresholds
        time_lock_base: u64,                           // base timelock (ms)
        time_lock_factor: u64,                         // divisor for additional time-based delay
    }

    /// A simple structure representing limits for periods and per-transaction caps.
    /// `copy, drop` means it is cheaply copyable and can be dropped (value type).
    public struct SpendingLimit has store, copy, drop {
        daily_limit: u64,
        weekly_limit: u64,
        monthly_limit: u64,
        per_tx_cap: u64,
    }

    /// Configure how many signatures are required depending on the amount.
    public struct AmountThreshold has store, copy, drop {
        max_amount: u64,            // upper bound for this bracket
        required_signatures: u64,   // signatures required if amount <= max_amount
    }

    /// Track spending totals to enforce daily/weekly/monthly rules.
    public struct SpendingTracker has store {
        daily_spent: Table<String, u64>,   // category -> amount spent today
        weekly_spent: Table<String, u64>,  // category -> amount spent this week
        monthly_spent: Table<String, u64>, // category -> amount spent this month
        global_daily: u64,                 // global daily total
        global_weekly: u64,                // global weekly total
        global_monthly: u64,               // global monthly total
        last_reset_day: u64,               // day epoch when daily counters last reset
        last_reset_week: u64,              // week epoch when weekly counters last reset
        last_reset_month: u64,             // month epoch when monthly counters last reset
    }

    /// Configuration and state for emergency operations.
    public struct EmergencyConfig has store {
        emergency_signers: vector<address>,    // subset (or same) signers allowed for emergencies
        emergency_threshold: u64,              // signatures required for emergency proposals
        last_emergency_ts: u64,                // timestamp of last emergency (ms)
        is_frozen: bool,                       // if frozen, emergency/normal ops might be blocked
    }

    /// Represents a spending proposal: multiple transactions, signatures, and metadata.
    public struct Proposal has key, store {
        id: UID,                       // unique object id for the proposal
        treasury_id: ID,               // id of parent treasury object (UID inner)
        proposer: address,             // who created the proposal (auto-signed)
        transactions: vector<Transaction>, // list of transactions to execute together
        category: String,              // category used for policy lookup (e.g., "Marketing")
        description: String,           // human description / memo
        signatures: vector<address>,   // addresses that have signed
        created_at: u64,               // creation timestamp (ms)
        time_lock_until: u64,          // earliest execution time (ms)
        executed: bool,                // whether the proposal has already been executed
        is_emergency: bool,            // flag indicating an emergency proposal
        total_amount: u64,             // pre-computed sum of amounts in `transactions`
    }

    /// Single transfer entry inside a proposal.
    public struct Transaction has store, copy, drop {
        recipient: address,
        amount: u64,
        category: String, // category is duplicated per-transaction for clarity
    }

    /// Capability object that grants administrative actions (stored as a resource).
    public struct TreasuryAdminCap has key, store {
        id: UID,
        treasury_id: ID,
    }

    // ------------------------------
    // Events: emitted for off-chain indexing and notifications
    // ------------------------------
    public struct TreasuryCreated has copy, drop {
        treasury_id: ID,
        name: String,
        signers: vector<address>,
        threshold: u64,
        timestamp: u64,
    }

    public struct ProposalCreated has copy, drop {
        proposal_id: ID,
        treasury_id: ID,
        proposer: address,
        category: String,
        total_amount: u64,
        time_lock_until: u64,
        timestamp: u64,
    }

    public struct ProposalSigned has copy, drop {
        proposal_id: ID,
        signer: address,
        signature_count: u64,
        timestamp: u64,
    }

    public struct ProposalExecuted has copy, drop {
        proposal_id: ID,
        treasury_id: ID,
        executed_by: address,
        total_amount: u64,
        timestamp: u64,
    }

    public struct EmergencyWithdrawal has copy, drop {
        treasury_id: ID,
        amount: u64,
        reason: String,
        timestamp: u64,
    }

    #[allow(unused_field)]
    public struct PolicyUpdated has copy, drop {
        treasury_id: ID,
        updated_by: address,
        timestamp: u64,
    }

    // ------------------------------
    // Public API / Entry points
    // ------------------------------

    /// Create a new treasury with initial configuration.
    /// - name: human readable name.
    /// - signers: vector of authorized signer addresses.
    /// - threshold: number of signatures required for normal proposals.
    /// - time_lock_base: base time lock in ms; 0 disables timelocks.
    /// - time_lock_factor: divisor for scaling extra timelock based on amount.
    /// - ctx: transaction context (provides sender, timestamp and other chain info).
    ///
    /// Returns the created Treasury resource and an admin capability.
    public fun create_treasury(
        name: String,
        signers: vector<address>,
        threshold: u64,
        time_lock_base: u64,
        time_lock_factor: u64,
        ctx: &mut TxContext
    ): (Treasury, TreasuryAdminCap) {
        // number of signers provided
        let signer_count = vector::length(&signers);
        
        // Input validation using `assert!`. On failure the transaction aborts with the code.
        assert!(threshold > 0 && threshold <= signer_count, EInvalidThreshold);
        assert!(signer_count > 0, EInvalidSigners);
        
        // Create a new object UID for treasury resource on-chain.
        // object::new(ctx) allocates a new resource ID bound to this transaction.
        let treasury_uid = object::new(ctx);
        // Get the raw inner ID (ID type rather than UID resource).
        let treasury_id = object::uid_to_inner(&treasury_uid);
        
        // Initialize the treasury resource with default policy structures and zero balance.
        let treasury = Treasury {
            id: treasury_uid,
            name,
            signers,
            threshold,
            balance_sui: balance::zero(), // start with zero SUI balance
            policy_config: PolicyConfig {
                spending_limits: table::new(ctx), // dynamic table mapping categories to limits
                global_limit: SpendingLimit {
                    daily_limit: 0, // zero indicates "no limit" in this codebase
                    weekly_limit: 0,
                    monthly_limit: 0,
                    per_tx_cap: 0,
                },
                whitelisted_addresses: vector::empty(),
                blacklisted_addresses: vector::empty(),
                category_thresholds: table::new(ctx),
                amount_thresholds: vector::empty(),
                time_lock_base,
                time_lock_factor,
            },
            spending_tracker: SpendingTracker {
                daily_spent: table::new(ctx),
                weekly_spent: table::new(ctx),
                monthly_spent: table::new(ctx),
                global_daily: 0,
                global_weekly: 0,
                global_monthly: 0,
                // last_reset_* store epoch counters (day/week/month) based on current timestamp
                last_reset_day: tx_context::epoch_timestamp_ms(ctx) / 86400000,
                last_reset_week: tx_context::epoch_timestamp_ms(ctx) / 604800000,
                last_reset_month: tx_context::epoch_timestamp_ms(ctx) / 2592000000,
            },
            proposal_count: 0,
            emergency_config: EmergencyConfig {
                emergency_signers: signers,
                // emergency threshold higher than normal to make emergency ops stricter
                emergency_threshold: threshold + 1,
                last_emergency_ts: 0,
                is_frozen: false,
            },
            created_at: tx_context::epoch_timestamp_ms(ctx),
        };

        // Create an admin capability resource tied to this treasury (grants admin actions).
        let admin_cap = TreasuryAdminCap {
            id: object::new(ctx),
            treasury_id,
        };

        // Emit event for external indexing / UIs.
        event::emit(TreasuryCreated {
            treasury_id,
            name: treasury.name,
            signers: treasury.signers,
            threshold: treasury.threshold,
            timestamp: treasury.created_at,
        });

        (treasury, admin_cap)
    }

    /// Convenience entry function to create a treasury and share the resulting objects with
    /// the transaction sender (useful for CLI workflows).
    /// `#[allow(lint(public_entry))]` allows this to be a public entry despite lints.
    #[allow(lint(public_entry))]
    public entry fun create_and_share_treasury(
        name: String,
        signers: vector<address>,
        threshold: u64,
        time_lock_base: u64,
        time_lock_factor: u64,
        ctx: &mut TxContext
    ) {
        // Reuse create_treasury to build the objects.
        let (treasury, admin_cap) = create_treasury(
            name,
            signers,
            threshold,
            time_lock_base,
            time_lock_factor,
            ctx
        );
        
        // `transfer::share_object` makes the object accessible to other parties (shared object semantics).
        transfer::share_object(treasury);
        // Transfer admin capability to transaction sender so they can perform admin actions.
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Deposit SUI coins into the treasury's internal `Balance<SUI>`.
    /// - `coin::into_balance` converts a Coin<SUI> into a Balance<SUI> resource.
    /// - `balance::join` merges two balances.
    public fun deposit_sui(
        treasury: &mut Treasury,
        coin: Coin<SUI>,
    ) {
        let balance = coin::into_balance(coin);
        balance::join(&mut treasury.balance_sui, balance);
    }

    /// Create a spending proposal consisting of up to MAX_BATCH_SIZE transactions.
    /// - Validates the proposer is an authorized signer.
    /// - Validates policy constraints (amounts, whitelist, etc).
    /// - Calculates and sets a time-lock based on policy.
    /// - Auto-signs by the proposer (adds proposer to `signatures`).
    public fun create_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ): Proposal {
        // The sender of the transaction that creates this proposal.
        let sender = tx_context::sender(ctx);
        
        // Ensure that the creator is an authorized signer.
        assert!(is_signer(treasury, sender), ENotSigner);
        
        // Enforce maximum batch size for proposals.
        assert!(vector::length(&transactions) <= MAX_BATCH_SIZE, EMaxBatchSizeExceeded);
        
        // Compute sum of all transaction amounts in the proposal.
        let total_amount = calculate_total_amount(&transactions);
        assert!(total_amount > 0, EInvalidAmount);
        
        // Validate the transactions against current policy configuration.
        validate_proposal_policies(treasury, &transactions, &category, total_amount, ctx);
        
        // Compute the time lock duration. This is policy-defined (base + scaled amount).
        let time_lock_duration = calculate_time_lock(
            &treasury.policy_config,
            total_amount,
            &category
        );
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        let time_lock_until = current_time + time_lock_duration;
        
        // Create an on-chain UID for the proposal object.
        let proposal_uid = object::new(ctx);
        let proposal_id = object::uid_to_inner(&proposal_uid);
        
        // Auto-sign by proposer: add sender to signatures so they count toward threshold.
        let mut signatures = vector::empty();
        vector::push_back(&mut signatures, sender);
        
        // Increment the treasury's proposal counter (on-chain state mutation).
        treasury.proposal_count = treasury.proposal_count + 1;
        
        // Emit ProposalCreated event for indexers / UIs.
        event::emit(ProposalCreated {
            proposal_id,
            treasury_id: object::uid_to_inner(&treasury.id),
            proposer: sender,
            category,
            total_amount,
            time_lock_until,
            timestamp: current_time,
        });
        
        // Build and return the Proposal resource (not shared by default).
        Proposal {
            id: proposal_uid,
            treasury_id: object::uid_to_inner(&treasury.id),
            proposer: sender,
            transactions,
            category,
            description,
            signatures,
            created_at: current_time,
            time_lock_until,
            executed: false,
            is_emergency: false,
            total_amount,
        }
    }

    /// Convenience to create and share a proposal object (makes it accessible externally).
    #[allow(lint(share_owned))]
    public fun create_and_share_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ) {
        let proposal = create_proposal(treasury, transactions, category, description, ctx);
        // Share the proposal object so it can be seen/acted upon by others.
        transfer::share_object(proposal);
    }

    /// Simple single-transaction proposal entry function for CLI/UX convenience.
    /// Builds a one-item `transactions` vector and reuses `create_proposal`.
    #[allow(lint(share_owned, public_entry))]
    public entry fun create_simple_proposal(
        treasury: &mut Treasury,
        recipient: address,
        amount: u64,
        category: String,
        description: String,
        ctx: &mut TxContext
    ) {
        let mut transactions = vector::empty();
        let tx = new_transaction(recipient, amount, category);
        vector::push_back(&mut transactions, tx);
        
        let proposal = create_proposal(treasury, transactions, category, description, ctx);
        transfer::share_object(proposal);
    }

    /// Sign a proposal to contribute toward its signature threshold.
    /// - Ensures the signer is authorized.
    /// - Ensures they haven't already signed.
    /// - Emits an event with the updated signature count.
    public fun sign_proposal(
        treasury: &Treasury,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Must be an authorized signer on this treasury.
        assert!(is_signer(treasury, sender), ENotSigner);
        
        // Prevent duplicate signatures from the same signer.
        assert!(!has_signed(proposal, sender), EAlreadySigned);
        
        // If already executed, signing is disallowed.
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        
        // Append signer to signature vector.
        vector::push_back(&mut proposal.signatures, sender);
        
        event::emit(ProposalSigned {
            proposal_id: object::uid_to_inner(&proposal.id),
            signer: sender,
            signature_count: vector::length(&proposal.signatures),
            timestamp: tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// Execute a proposal that has reached the required threshold and whose time-lock expired.
    /// - Verifies the proposal belongs to the provided treasury.
    /// - Ensures sufficient signatures for either normal or emergency execution.
    /// - Re-validates policies just before execution.
    /// - Performs all transactions atomically in a loop.
    public fun execute_proposal(
        treasury: &mut Treasury,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        
        // Proposal must be owned by this treasury.
        assert!(proposal.treasury_id == object::uid_to_inner(&treasury.id), EProposalNotFound);
        
        // Must not have been executed before.
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        
        // Time lock must have expired.
        assert!(current_time >= proposal.time_lock_until, ETimeLockNotExpired);
        
        // Determine required signature threshold (emergency vs normal).
        let signature_count = vector::length(&proposal.signatures);
        let required_threshold = if (proposal.is_emergency) {
            treasury.emergency_config.emergency_threshold
        } else {
            treasury.threshold
        };
        assert!(signature_count >= required_threshold, EInsufficientSignatures);
        
        // Reset periodic trackers if the epoch has advanced.
        reset_spending_trackers(treasury, current_time);
        
        // Re-validate policies immediately prior to executing transfers to avoid TOCTOU policy bypass.
        validate_proposal_policies(
            treasury, 
            &proposal.transactions, 
            &proposal.category, 
            proposal.total_amount,
            ctx
        );
        
        // Execute all transactions in the proposal sequentially.
        let mut i = 0;
        let len = vector::length(&proposal.transactions);
        while (i < len) {
            // vector::borrow returns an immutable reference to the transaction at index `i`.
            let tx = vector::borrow(&proposal.transactions, i);
            // Perform the withdrawal and transfer for this transaction.
            execute_transaction(treasury, tx, &proposal.category, ctx);
            i = i + 1;
        };
        
        // Mark the proposal as executed to prevent replay.
        proposal.executed = true;
        
        event::emit(ProposalExecuted {
            proposal_id: object::uid_to_inner(&proposal.id),
            treasury_id: proposal.treasury_id,
            executed_by: sender,
            total_amount: proposal.total_amount,
            timestamp: current_time,
        });
    }

    // ------------------------------
    // Policy Management (admin-only functions)
    // ------------------------------

    /// Set per-category spending limit. Requires admin capability to call in practice.
    /// This function replaces an existing limit (if present).
    public fun set_category_limit(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        category: String,
        limit: SpendingLimit,
    ) {
        // Table stores values by key; remove existing then add new (keeps semantics clear).
        if (table::contains(&treasury.policy_config.spending_limits, category)) {
            table::remove(&mut treasury.policy_config.spending_limits, category);
        };
        table::add(&mut treasury.policy_config.spending_limits, category, limit);
    }

    /// Set the global fallback spending limit.
    public fun set_global_limit(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        limit: SpendingLimit,
    ) {
        treasury.policy_config.global_limit = limit;
    }

    /// Add an address to the whitelist (if it's not already present).
    /// If the whitelist is non-empty, proposals will restrict recipients to members of this list.
    public fun add_whitelist(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        addr: address,
    ) {
        if (!vector::contains(&treasury.policy_config.whitelisted_addresses, &addr)) {
            vector::push_back(&mut treasury.policy_config.whitelisted_addresses, addr);
        };
    }

    /// Add an amount-based threshold entry that maps an upper bound to a required signature count.
    public fun add_amount_threshold(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        threshold: AmountThreshold,
    ) {
        vector::push_back(&mut treasury.policy_config.amount_thresholds, threshold);
    }

    // ------------------------------
    // Internal helper functions
    // ------------------------------

    /// Check whether an address is in the treasury `signers` vector.
    fun is_signer(treasury: &Treasury, addr: address): bool {
        vector::contains(&treasury.signers, &addr)
    }

    /// Check whether an address already signed a given proposal.
    fun has_signed(proposal: &Proposal, addr: address): bool {
        vector::contains(&proposal.signatures, &addr)
    }

    /// Sum the amounts of all transactions in a vector.
    /// Note: careful about overflow in real-world usage; Move u64 will wrap on overflow if not checked.
    fun calculate_total_amount(transactions: &vector<Transaction>): u64 {
        let mut total = 0;
        let mut i = 0;
        let len = vector::length(transactions);
        while (i < len) {
            let tx = vector::borrow(transactions, i);
            total = total + tx.amount;
            i = i + 1;
        };
        total
    }

    /// Calculate an absolute timelock duration based on policy config and amount.
    /// Returns `time_lock_base + (amount / time_lock_factor)` when configured; 0 if base is 0.
    fun calculate_time_lock(
        config: &PolicyConfig,
        amount: u64,
        _category: &String
    ): u64 {
        if (config.time_lock_base == 0) {
            return 0
        };
        let additional = if (config.time_lock_factor > 0) {
            amount / config.time_lock_factor
        } else {
            0
        };
        config.time_lock_base + additional
    }

    /// Validate proposal-level policy constraints:
    /// - per-tx cap (global)
    /// - whitelist enforcement (if whitelist is non-empty)
    /// - category-specific spending limits (delegates to validate_spending_limit)
    fun validate_proposal_policies(
        treasury: &Treasury,
        transactions: &vector<Transaction>,
        category: &String,
        total_amount: u64,
        _ctx: &TxContext
    ) {
        let config = &treasury.policy_config;
        
        // Global per-transaction cap: if > 0, ensure total_amount does not exceed it.
        if (config.global_limit.per_tx_cap > 0) {
            assert!(total_amount <= config.global_limit.per_tx_cap, EPolicyViolation);
        };
        
        // Enforce whitelist: if the whitelist is non-empty, every tx.recipient must be present.
        if (!vector::is_empty(&config.whitelisted_addresses)) {
            let mut i = 0;
            let len = vector::length(transactions);
            while (i < len) {
                let tx = vector::borrow(transactions, i);
                assert!(
                    vector::contains(&config.whitelisted_addresses, &tx.recipient),
                    ENotWhitelisted
                );
                i = i + 1;
            };
        };
        
        // If we have a category-specific spending limit, validate against tracker and limit.
        if (table::contains(&config.spending_limits, *category)) {
            let limit = table::borrow(&config.spending_limits, *category);
            validate_spending_limit(treasury, category, total_amount, limit);
        };
    }

    /// Validate spending limits against the current tracker state for a single category.
    /// This sample only checks daily limits; extend similarly for weekly/monthly/global checks as needed.
    fun validate_spending_limit(
        treasury: &Treasury,
        category: &String,
        amount: u64,
        limit: &SpendingLimit
    ) {
        let tracker = &treasury.spending_tracker;
        
        // Check daily limit if configured (> 0).
        if (limit.daily_limit > 0) {
            let current_daily = if (table::contains(&tracker.daily_spent, *category)) {
                *table::borrow(&tracker.daily_spent, *category)
            } else {
                0
            };
            // Ensure adding `amount` does not exceed allowed daily limit.
            assert!(current_daily + amount <= limit.daily_limit, ESpendingLimitExceeded);
        };
    }

    /// Reset the global daily/weekly/monthly counters if the epoch counters moved forward.
    /// Uses integer division to compute day/week/month epoch numbers.
    fun reset_spending_trackers(treasury: &mut Treasury, current_time: u64) {
        let current_day = current_time / 86400000;
        let current_week = current_time / 604800000;
        let current_month = current_time / 2592000000;
        
        // Reset daily totals if a new day began.
        if (current_day > treasury.spending_tracker.last_reset_day) {
            treasury.spending_tracker.global_daily = 0;
            treasury.spending_tracker.last_reset_day = current_day;
        };
        
        // Reset weekly totals if a new week began.
        if (current_week > treasury.spending_tracker.last_reset_week) {
            treasury.spending_tracker.global_weekly = 0;
            treasury.spending_tracker.last_reset_week = current_week;
        };
        
        // Reset monthly totals if a new month began.
        if (current_month > treasury.spending_tracker.last_reset_month) {
            treasury.spending_tracker.global_monthly = 0;
            treasury.spending_tracker.last_reset_month = current_month;
        };
    }

    /// Execute a single transaction:
    /// - Withdraw `tx.amount` from treasury.balance_sui by splitting the Balance and creating a Coin.
    /// - Transfer the Coin to the recipient.
    /// - Update spending trackers to reflect the outgoing amount.
    fun execute_transaction(
        treasury: &mut Treasury,
        tx: &Transaction,
        category: &String,
        ctx: &mut TxContext
    ) {
        // `balance::split` reduces the balance resource by `tx.amount` and returns a new Balance<SUI>.
        // `coin::from_balance` converts that Balance<SUI> into a Coin<SUI> so it can be sent.
        let coin = coin::from_balance(
            balance::split(&mut treasury.balance_sui, tx.amount),
            ctx
        );
        
        // `transfer::public_transfer` sends the Coin to the recipient address.
        transfer::public_transfer(coin, tx.recipient);
        
        // Update per-category and global trackers.
        update_spending_tracker(treasury, category, tx.amount);
    }

    /// Update the per-category daily table and global counters.
    /// - If category exists, `table::borrow_mut` fetches a mutable reference to the stored u64.
    /// - If not, `table::add` creates a new entry with the amount.
    fun update_spending_tracker(
        treasury: &mut Treasury,
        category: &String,
        amount: u64
    ) {
        let tracker = &mut treasury.spending_tracker;
        
        // Update category daily table.
        if (table::contains(&tracker.daily_spent, *category)) {
            let spent = table::borrow_mut(&mut tracker.daily_spent, *category);
            *spent = *spent + amount;
        } else {
            table::add(&mut tracker.daily_spent, *category, amount);
        };
        
        // Update global counters.
        tracker.global_daily = tracker.global_daily + amount;
        tracker.global_weekly = tracker.global_weekly + amount;
        tracker.global_monthly = tracker.global_monthly + amount;
    }

    // ------------------------------
    // Read-only view helpers (pure getters)
    // ------------------------------

    /// Return the numeric SUI balance value from the Balance<SUI> resource.
    public fun get_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.balance_sui)
    }

    /// Return the list of signer addresses.
    public fun get_signers(treasury: &Treasury): vector<address> {
        treasury.signers
    }

    /// Return the configured threshold for normal proposals.
    public fun get_threshold(treasury: &Treasury): u64 {
        treasury.threshold
    }

    /// How many signers have signed a proposal so far.
    public fun get_signature_count(proposal: &Proposal): u64 {
        vector::length(&proposal.signatures)
    }

    /// Whether the proposal has been executed already.
    public fun is_executed(proposal: &Proposal): bool {
        proposal.executed
    }

    /// Total amount attached to the proposal.
    public fun get_proposal_amount(proposal: &Proposal): u64 {
        proposal.total_amount
    }

    /// Category string of the proposal.
    public fun get_proposal_category(proposal: &Proposal): String {
        proposal.category
    }

    // ------------------------------
    // Constructors (convenience creators)
    // ------------------------------

    /// Create a Transaction struct (value type).
    public fun new_transaction(
        recipient: address,
        amount: u64,
        category: String
    ): Transaction {
        Transaction {
            recipient,
            amount,
            category,
        }
    }

    /// Create a SpendingLimit value.
    public fun new_spending_limit(
        daily_limit: u64,
        weekly_limit: u64,
        monthly_limit: u64,
        per_tx_cap: u64
    ): SpendingLimit {
        SpendingLimit {
            daily_limit,
            weekly_limit,
            monthly_limit,
            per_tx_cap,
        }
    }

    /// Create an AmountThreshold value.
    public fun new_amount_threshold(
        max_amount: u64,
        required_signatures: u64
    ): AmountThreshold {
        AmountThreshold {
            max_amount,
            required_signatures,
        }
    }

    // ------------------------------
    // Emergency flows (special higher-security flows)
    // ------------------------------

    /// Create an emergency proposal:
    /// - Must be created by an emergency signer.
    /// - Must respect a cooldown between emergencies.
    /// - Uses a shorter timelock (halved here) for faster action.
    /// - Emits an EmergencyWithdrawal event (for off-chain alerts).
    public fun create_emergency_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ): Proposal {
        let sender = tx_context::sender(ctx);
        
        // Ensure the creator is allowed to create emergency proposals.
        assert!(
            vector::contains(&treasury.emergency_config.emergency_signers, &sender),
            ENotSigner
        );
        
        // Enforce cooldown period since last emergency.
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        assert!(
            current_time >= treasury.emergency_config.last_emergency_ts + EMERGENCY_COOLDOWN_PERIOD,
            EInCooldownPeriod
        );
        
        // If the treasury is frozen, emergency ops are blocked.
        assert!(!treasury.emergency_config.is_frozen, EPolicyViolation);
        
        let total_amount = calculate_total_amount(&transactions);
        
        // Emergency uses a reduced time lock for fast response (divide by 2).
        let time_lock_duration = calculate_time_lock(
            &treasury.policy_config,
            total_amount,
            &category
        ) / 2;
        
        let time_lock_until = current_time + time_lock_duration;
        
        let proposal_uid = object::new(ctx);
        
        let mut signatures = vector::empty();
        vector::push_back(&mut signatures, sender);
        
        // Bookkeeping: increment counters and update last emergency timestamp.
        treasury.proposal_count = treasury.proposal_count + 1;
        treasury.emergency_config.last_emergency_ts = current_time;
        
        let proposal = Proposal {
            id: proposal_uid,
            treasury_id: object::uid_to_inner(&treasury.id),
            proposer: sender,
            transactions,
            category,
            description,
            signatures,
            created_at: current_time,
            time_lock_until,
            executed: false,
            is_emergency: true,
            total_amount,
        };
        
        // Emit a specific emergency event so monitors can react.
        event::emit(EmergencyWithdrawal {
            treasury_id: object::uid_to_inner(&treasury.id),
            amount: total_amount,
            reason: proposal.description,
            timestamp: current_time,
        });
        
        proposal
    }

    /// Freeze the treasury to block certain operations (admin-only action).
    public fun freeze_treasury(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
    ) {
        treasury.emergency_config.is_frozen = true;
    }

    /// Unfreeze the treasury to resume operations (admin-only action).
    public fun unfreeze_treasury(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
    ) {
        treasury.emergency_config.is_frozen = false;
    }

    // ------------------------------
    // Signer management (admin-only)
    // ------------------------------

    /// Add a new signer address to the treasury signers vector.
    public fun add_signer(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        new_signer: address,
    ) {
        // Ensure the signer is not already present.
        assert!(!vector::contains(&treasury.signers, &new_signer), EPolicyViolation);
        vector::push_back(&mut treasury.signers, new_signer);
    }

    /// Remove a signer by address. Ensures threshold remains valid afterwards.
    public fun remove_signer(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        signer: address,
    ) {
        // `vector::index_of` returns (exists, index). If not found, abort.
        let (exists, index) = vector::index_of(&treasury.signers, &signer);
        assert!(exists, ENotSigner);
        
        // Remove the signer at the found index.
        vector::remove(&mut treasury.signers, index);
        
        // After removal, ensure the threshold is still <= signer_count.
        let signer_count = vector::length(&treasury.signers);
        assert!(treasury.threshold <= signer_count, EInvalidThreshold);
    }

    /// Update the threshold for normal proposals. Must be > 0 and <= signer_count.
    public fun update_threshold(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        new_threshold: u64,
    ) {
        let signer_count = vector::length(&treasury.signers);
        assert!(new_threshold > 0 && new_threshold <= signer_count, EInvalidThreshold);
        treasury.threshold = new_threshold;
    }
}
