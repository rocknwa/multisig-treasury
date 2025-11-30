module multisig_treasury::treasury {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::event;
    use std::string::String;

    // =================== Error Codes ===================
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

    // =================== Constants ===================
    const MAX_BATCH_SIZE: u64 = 50;
    const EMERGENCY_COOLDOWN_PERIOD: u64 = 86400000; // 24 hours in ms

    // =================== Structs ===================

    /// Main treasury object holding funds and configuration
    public struct Treasury has key, store {
        id: UID,
        name: String,
        signers: vector<address>,
        threshold: u64,
        balance_sui: Balance<SUI>,
        policy_config: PolicyConfig,
        spending_tracker: SpendingTracker,
        proposal_count: u64,
        emergency_config: EmergencyConfig,
        created_at: u64,
    }

    /// Policy configuration for the treasury
    public struct PolicyConfig has store {
        spending_limits: Table<String, SpendingLimit>, // category -> limit
        global_limit: SpendingLimit,
        whitelisted_addresses: vector<address>,
        blacklisted_addresses: vector<address>,
        category_thresholds: Table<String, u64>, // category -> required signatures
        amount_thresholds: vector<AmountThreshold>,
        time_lock_base: u64, // base time lock in ms
        time_lock_factor: u64, // amount divisor for additional time lock
    }

    /// Spending limit per time period
    public struct SpendingLimit has store, copy, drop {
        daily_limit: u64,
        weekly_limit: u64,
        monthly_limit: u64,
        per_tx_cap: u64,
    }

    /// Amount threshold configuration
    public struct AmountThreshold has store, copy, drop {
        max_amount: u64,
        required_signatures: u64,
    }

    /// Track spending across time periods
    public struct SpendingTracker has store {
        daily_spent: Table<String, u64>, // category -> amount
        weekly_spent: Table<String, u64>,
        monthly_spent: Table<String, u64>,
        global_daily: u64,
        global_weekly: u64,
        global_monthly: u64,
        last_reset_day: u64,
        last_reset_week: u64,
        last_reset_month: u64,
    }

    /// Emergency configuration
    public struct EmergencyConfig has store {
        emergency_signers: vector<address>,
        emergency_threshold: u64,
        last_emergency_ts: u64,
        is_frozen: bool,
    }

    /// Spending proposal
    public struct Proposal has key, store {
        id: UID,
        treasury_id: ID,
        proposer: address,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        signatures: vector<address>,
        created_at: u64,
        time_lock_until: u64,
        executed: bool,
        is_emergency: bool,
        total_amount: u64,
    }

    /// Single transaction in a proposal
    public struct Transaction has store, copy, drop {
        recipient: address,
        amount: u64,
        category: String,
    }

    /// Treasury capability for administrative actions
    public struct TreasuryAdminCap has key, store {
        id: UID,
        treasury_id: ID,
    }

    // =================== Events ===================

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

    // =================== Public Functions ===================

    /// Create a new treasury with initial configuration
    public fun create_treasury(
        name: String,
        signers: vector<address>,
        threshold: u64,
        time_lock_base: u64,
        time_lock_factor: u64,
        ctx: &mut TxContext
    ): (Treasury, TreasuryAdminCap) {
        let signer_count = vector::length(&signers);
        
        // Validate inputs
        assert!(threshold > 0 && threshold <= signer_count, EInvalidThreshold);
        assert!(signer_count > 0, EInvalidSigners);
        
        let treasury_uid = object::new(ctx);
        let treasury_id = object::uid_to_inner(&treasury_uid);
        
        let treasury = Treasury {
            id: treasury_uid,
            name,
            signers,
            threshold,
            balance_sui: balance::zero(),
            policy_config: PolicyConfig {
                spending_limits: table::new(ctx),
                global_limit: SpendingLimit {
                    daily_limit: 0, // 0 means no limit
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
                last_reset_day: tx_context::epoch_timestamp_ms(ctx) / 86400000,
                last_reset_week: tx_context::epoch_timestamp_ms(ctx) / 604800000,
                last_reset_month: tx_context::epoch_timestamp_ms(ctx) / 2592000000,
            },
            proposal_count: 0,
            emergency_config: EmergencyConfig {
                emergency_signers: signers,
                emergency_threshold: threshold + 1, // Higher threshold for emergencies
                last_emergency_ts: 0,
                is_frozen: false,
            },
            created_at: tx_context::epoch_timestamp_ms(ctx),
        };

        let admin_cap = TreasuryAdminCap {
            id: object::new(ctx),
            treasury_id,
        };

        event::emit(TreasuryCreated {
            treasury_id,
            name: treasury.name,
            signers: treasury.signers,
            threshold: treasury.threshold,
            timestamp: treasury.created_at,
        });

        (treasury, admin_cap)
    }

    /// Create and share a new treasury (convenience function for CLI)
    #[allow(lint(public_entry))]
    public entry fun create_and_share_treasury(
        name: String,
        signers: vector<address>,
        threshold: u64,
        time_lock_base: u64,
        time_lock_factor: u64,
        ctx: &mut TxContext
    ) {
        let (treasury, admin_cap) = create_treasury(
            name,
            signers,
            threshold,
            time_lock_base,
            time_lock_factor,
            ctx
        );
        
        transfer::share_object(treasury);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Deposit SUI into treasury
    public fun deposit_sui(
        treasury: &mut Treasury,
        coin: Coin<SUI>,
    ) {
        let balance = coin::into_balance(coin);
        balance::join(&mut treasury.balance_sui, balance);
    }

    /// Create a spending proposal
    public fun create_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ): Proposal {
        let sender = tx_context::sender(ctx);
        
        // Verify sender is a signer
        assert!(is_signer(treasury, sender), ENotSigner);
        
        // Validate batch size
        assert!(vector::length(&transactions) <= MAX_BATCH_SIZE, EMaxBatchSizeExceeded);
        
        // Calculate total amount and validate
        let total_amount = calculate_total_amount(&transactions);
        assert!(total_amount > 0, EInvalidAmount);
        
        // Validate against policies
        validate_proposal_policies(treasury, &transactions, &category, total_amount, ctx);
        
        // Calculate time lock
        let time_lock_duration = calculate_time_lock(
            &treasury.policy_config,
            total_amount,
            &category
        );
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        let time_lock_until = current_time + time_lock_duration;
        
        let proposal_uid = object::new(ctx);
        let proposal_id = object::uid_to_inner(&proposal_uid);
        
        // Auto-sign by proposer
        let mut signatures = vector::empty();
        vector::push_back(&mut signatures, sender);
        
        treasury.proposal_count = treasury.proposal_count + 1;
        
        event::emit(ProposalCreated {
            proposal_id,
            treasury_id: object::uid_to_inner(&treasury.id),
            proposer: sender,
            category,
            total_amount,
            time_lock_until,
            timestamp: current_time,
        });
        
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

    /// Create and share a spending proposal (convenience function for CLI)
    #[allow(lint(share_owned))]
    public fun create_and_share_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ) {
        let proposal = create_proposal(treasury, transactions, category, description, ctx);
        transfer::share_object(proposal);
    }

    /// Sign a proposal
    public fun sign_proposal(
        treasury: &Treasury,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Verify sender is a signer
        assert!(is_signer(treasury, sender), ENotSigner);
        
        // Check not already signed
        assert!(!has_signed(proposal, sender), EAlreadySigned);
        
        // Check not already executed
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        
        vector::push_back(&mut proposal.signatures, sender);
        
        event::emit(ProposalSigned {
            proposal_id: object::uid_to_inner(&proposal.id),
            signer: sender,
            signature_count: vector::length(&proposal.signatures),
            timestamp: tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// Execute an approved proposal
    public fun execute_proposal(
        treasury: &mut Treasury,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        
        // Verify proposal belongs to this treasury
        assert!(proposal.treasury_id == object::uid_to_inner(&treasury.id), EProposalNotFound);
        
        // Check not already executed
        assert!(!proposal.executed, EProposalAlreadyExecuted);
        
        // Check time lock expired
        assert!(current_time >= proposal.time_lock_until, ETimeLockNotExpired);
        
        // Check threshold met
        let signature_count = vector::length(&proposal.signatures);
        let required_threshold = if (proposal.is_emergency) {
            treasury.emergency_config.emergency_threshold
        } else {
            treasury.threshold
        };
        assert!(signature_count >= required_threshold, EInsufficientSignatures);
        
        // Reset spending trackers if needed
        reset_spending_trackers(treasury, current_time);
        
        // Re-validate policies before execution
        validate_proposal_policies(
            treasury, 
            &proposal.transactions, 
            &proposal.category, 
            proposal.total_amount,
            ctx
        );
        
        // Execute all transactions
        let mut i = 0;
        let len = vector::length(&proposal.transactions);
        while (i < len) {
            let tx = vector::borrow(&proposal.transactions, i);
            execute_transaction(treasury, tx, &proposal.category, ctx);
            i = i + 1;
        };
        
        proposal.executed = true;
        
        event::emit(ProposalExecuted {
            proposal_id: object::uid_to_inner(&proposal.id),
            treasury_id: proposal.treasury_id,
            executed_by: sender,
            total_amount: proposal.total_amount,
            timestamp: current_time,
        });
    }

    // =================== Policy Management ===================

    /// Set spending limit for a category
    public fun set_category_limit(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        category: String,
        limit: SpendingLimit,
    ) {
        if (table::contains(&treasury.policy_config.spending_limits, category)) {
            table::remove(&mut treasury.policy_config.spending_limits, category);
        };
        table::add(&mut treasury.policy_config.spending_limits, category, limit);
    }

    /// Set global spending limit
    public fun set_global_limit(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        limit: SpendingLimit,
    ) {
        treasury.policy_config.global_limit = limit;
    }

    /// Add whitelisted address
    public fun add_whitelist(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        addr: address,
    ) {
        if (!vector::contains(&treasury.policy_config.whitelisted_addresses, &addr)) {
            vector::push_back(&mut treasury.policy_config.whitelisted_addresses, addr);
        };
    }

    /// Add amount threshold
    public fun add_amount_threshold(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        threshold: AmountThreshold,
    ) {
        vector::push_back(&mut treasury.policy_config.amount_thresholds, threshold);
    }

    // =================== Helper Functions ===================

    fun is_signer(treasury: &Treasury, addr: address): bool {
        vector::contains(&treasury.signers, &addr)
    }

    fun has_signed(proposal: &Proposal, addr: address): bool {
        vector::contains(&proposal.signatures, &addr)
    }

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

    fun validate_proposal_policies(
        treasury: &Treasury,
        transactions: &vector<Transaction>,
        category: &String,
        total_amount: u64,
        _ctx: &TxContext
    ) {
        let config = &treasury.policy_config;
        
        // Check per-transaction cap
        if (config.global_limit.per_tx_cap > 0) {
            assert!(total_amount <= config.global_limit.per_tx_cap, EPolicyViolation);
        };
        
        // Check whitelist
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
        
        // Check category-specific limits
        if (table::contains(&config.spending_limits, *category)) {
            let limit = table::borrow(&config.spending_limits, *category);
            validate_spending_limit(treasury, category, total_amount, limit);
        };
    }

    fun validate_spending_limit(
        treasury: &Treasury,
        category: &String,
        amount: u64,
        limit: &SpendingLimit
    ) {
        let tracker = &treasury.spending_tracker;
        
        // Check daily limit
        if (limit.daily_limit > 0) {
            let current_daily = if (table::contains(&tracker.daily_spent, *category)) {
                *table::borrow(&tracker.daily_spent, *category)
            } else {
                0
            };
            assert!(current_daily + amount <= limit.daily_limit, ESpendingLimitExceeded);
        };
    }

    fun reset_spending_trackers(treasury: &mut Treasury, current_time: u64) {
        let current_day = current_time / 86400000;
        let current_week = current_time / 604800000;
        let current_month = current_time / 2592000000;
        
        // Reset daily if needed
        if (current_day > treasury.spending_tracker.last_reset_day) {
            treasury.spending_tracker.global_daily = 0;
            treasury.spending_tracker.last_reset_day = current_day;
        };
        
        // Reset weekly if needed
        if (current_week > treasury.spending_tracker.last_reset_week) {
            treasury.spending_tracker.global_weekly = 0;
            treasury.spending_tracker.last_reset_week = current_week;
        };
        
        // Reset monthly if needed
        if (current_month > treasury.spending_tracker.last_reset_month) {
            treasury.spending_tracker.global_monthly = 0;
            treasury.spending_tracker.last_reset_month = current_month;
        };
    }

    fun execute_transaction(
        treasury: &mut Treasury,
        tx: &Transaction,
        category: &String,
        ctx: &mut TxContext
    ) {
        // Withdraw from treasury
        let coin = coin::from_balance(
            balance::split(&mut treasury.balance_sui, tx.amount),
            ctx
        );
        
        // Transfer to recipient
        transfer::public_transfer(coin, tx.recipient);
        
        // Update spending tracker
        update_spending_tracker(treasury, category, tx.amount);
    }

    fun update_spending_tracker(
        treasury: &mut Treasury,
        category: &String,
        amount: u64
    ) {
        let tracker = &mut treasury.spending_tracker;
        
        // Update category daily
        if (table::contains(&tracker.daily_spent, *category)) {
            let spent = table::borrow_mut(&mut tracker.daily_spent, *category);
            *spent = *spent + amount;
        } else {
            table::add(&mut tracker.daily_spent, *category, amount);
        };
        
        // Update global
        tracker.global_daily = tracker.global_daily + amount;
        tracker.global_weekly = tracker.global_weekly + amount;
        tracker.global_monthly = tracker.global_monthly + amount;
    }

    // =================== View Functions ===================

    public fun get_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.balance_sui)
    }

    public fun get_signers(treasury: &Treasury): vector<address> {
        treasury.signers
    }

    public fun get_threshold(treasury: &Treasury): u64 {
        treasury.threshold
    }

    public fun get_signature_count(proposal: &Proposal): u64 {
        vector::length(&proposal.signatures)
    }

    public fun is_executed(proposal: &Proposal): bool {
        proposal.executed
    }

    public fun get_proposal_amount(proposal: &Proposal): u64 {
        proposal.total_amount
    }

    public fun get_proposal_category(proposal: &Proposal): String {
        proposal.category
    }

    // =================== Constructor Functions ===================

    /// Create a new transaction struct
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

    /// Create a new spending limit
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

    /// Create a new amount threshold
    public fun new_amount_threshold(
        max_amount: u64,
        required_signatures: u64
    ): AmountThreshold {
        AmountThreshold {
            max_amount,
            required_signatures,
        }
    }

    // =================== Emergency Functions ===================

    /// Create an emergency proposal
    public fun create_emergency_proposal(
        treasury: &mut Treasury,
        transactions: vector<Transaction>,
        category: String,
        description: String,
        ctx: &mut TxContext
    ): Proposal {
        let sender = tx_context::sender(ctx);
        
        // Verify sender is an emergency signer
        assert!(
            vector::contains(&treasury.emergency_config.emergency_signers, &sender),
            ENotSigner
        );
        
        // Check not in cooldown
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        assert!(
            current_time >= treasury.emergency_config.last_emergency_ts + EMERGENCY_COOLDOWN_PERIOD,
            EInCooldownPeriod
        );
        
        // Validate not frozen
        assert!(!treasury.emergency_config.is_frozen, EPolicyViolation);
        
        let total_amount = calculate_total_amount(&transactions);
        
        // Shorter time lock for emergencies (half the normal)
        let time_lock_duration = calculate_time_lock(
            &treasury.policy_config,
            total_amount,
            &category
        ) / 2;
        
        let time_lock_until = current_time + time_lock_duration;
        
        let proposal_uid = object::new(ctx);
        
        let mut signatures = vector::empty();
        vector::push_back(&mut signatures, sender);
        
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
        
        event::emit(EmergencyWithdrawal {
            treasury_id: object::uid_to_inner(&treasury.id),
            amount: total_amount,
            reason: proposal.description,
            timestamp: current_time,
        });
        
        proposal
    }

    /// Freeze treasury (emergency only)
    public fun freeze_treasury(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
    ) {
        treasury.emergency_config.is_frozen = true;
    }

    /// Unfreeze treasury
    public fun unfreeze_treasury(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
    ) {
        treasury.emergency_config.is_frozen = false;
    }

    // =================== Signer Management ===================

    /// Add a new signer (requires admin cap)
    public fun add_signer(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        new_signer: address,
    ) {
        assert!(!vector::contains(&treasury.signers, &new_signer), EPolicyViolation);
        vector::push_back(&mut treasury.signers, new_signer);
    }

    /// Remove a signer (requires admin cap)
    public fun remove_signer(
        treasury: &mut Treasury,
        _admin_cap: &TreasuryAdminCap,
        signer: address,
    ) {
        let (exists, index) = vector::index_of(&treasury.signers, &signer);
        assert!(exists, ENotSigner);
        
        vector::remove(&mut treasury.signers, index);
        
        // Ensure threshold is still valid
        let signer_count = vector::length(&treasury.signers);
        assert!(treasury.threshold <= signer_count, EInvalidThreshold);
    }

    /// Update threshold (requires admin cap)
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