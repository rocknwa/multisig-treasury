#[test_only]
module multisig_treasury::treasury_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::sui::SUI;
    use multisig_treasury::treasury::{
        Self, 
        Treasury, 
        Proposal,
        Transaction,
    };
    use std::string::{Self, String};

    // Test addresses
    const ADMIN: address = @0xA;
    const SIGNER1: address = @0xB;
    const SIGNER2: address = @0xC;
    const SIGNER3: address = @0xD;
    const RECIPIENT: address = @0xE;
    const NON_SIGNER: address = @0xF;

    // Helper function to create signers vector
    fun create_signers(): vector<address> {
        let mut signers = vector::empty();
        vector::push_back(&mut signers, ADMIN);
        vector::push_back(&mut signers, SIGNER1);
        vector::push_back(&mut signers, SIGNER2);
        vector::push_back(&mut signers, SIGNER3);
        signers
    }

    // Helper to create a simple transaction
    fun create_transaction(recipient: address, amount: u64, category: String): Transaction {
        treasury::new_transaction(recipient, amount, category)
    }

    // =================== Treasury Creation Tests ===================

    #[test]
    fun test_create_treasury_success() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3, // threshold
                3600000, // 1 hour base timelock
                1000, // timelock factor
                ts::ctx(&mut scenario)
            );
            
            assert!(treasury::get_threshold(&treasury) == 3, 0);
            assert!(vector::length(&treasury::get_signers(&treasury)) == 4, 1);
            assert!(treasury::get_balance(&treasury) == 0, 2);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidThreshold)]
    fun test_create_treasury_invalid_threshold_too_high() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                5, // threshold > signer count
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidThreshold)]
    fun test_create_treasury_zero_threshold() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                0, // invalid
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidThreshold)]
    fun test_create_treasury_no_signers() {
        let mut scenario = ts::begin(ADMIN);
        let signers = vector::empty<address>();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                1,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    // =================== Deposit Tests ===================

    #[test]
    fun test_deposit_sui() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Create treasury
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Deposit SUI
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let coin = coin::mint_for_testing<SUI>(1000000000, ts::ctx(&mut scenario));
            
            treasury::deposit_sui(&mut treasury, coin);
            assert!(treasury::get_balance(&treasury) == 1000000000, 0);
            
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_deposits() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Create treasury
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // First deposit
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let coin = coin::mint_for_testing<SUI>(1000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            ts::return_shared(treasury);
        };
        
        // Second deposit
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let coin = coin::mint_for_testing<SUI>(2000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            assert!(treasury::get_balance(&treasury) == 3000, 0);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    // =================== Proposal Creation Tests ===================

    #[test]
    fun test_create_proposal_single_transaction() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            let coin = coin::mint_for_testing<SUI>(1000000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create proposal
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            let tx = create_transaction(RECIPIENT, 100000, string::utf8(b"Operations"));
            vector::push_back(&mut transactions, tx);
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"Monthly operational expenses"),
                ts::ctx(&mut scenario)
            );
            
            // Proposer automatically signs
            assert!(treasury::get_signature_count(&proposal) == 1, 0);
            assert!(!treasury::is_executed(&proposal), 1);
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_create_proposal_batch_transactions() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            let coin = coin::mint_for_testing<SUI>(1000000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create batch proposal
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            
            // Add multiple transactions
            vector::push_back(&mut transactions, 
                create_transaction(RECIPIENT, 10000, string::utf8(b"Marketing")));
            vector::push_back(&mut transactions, 
                create_transaction(SIGNER1, 20000, string::utf8(b"Marketing")));
            vector::push_back(&mut transactions, 
                create_transaction(SIGNER2, 15000, string::utf8(b"Marketing")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Marketing"),
                string::utf8(b"Q4 Marketing Campaign"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ENotSigner)]
    fun test_create_proposal_non_signer() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Non-signer tries to create proposal
        ts::next_tx(&mut scenario, NON_SIGNER);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                create_transaction(RECIPIENT, 100, string::utf8(b"Test")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Test"),
                string::utf8(b"Test"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidAmount)]
    fun test_create_proposal_zero_amount() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                create_transaction(RECIPIENT, 0, string::utf8(b"Test")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Test"),
                string::utf8(b"Test"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    // =================== Signature Tests ===================

    #[test]
    fun test_sign_proposal() {
        let mut scenario = setup_proposal_scenario();
        
        // SIGNER1 signs
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            assert!(treasury::get_signature_count(&proposal) == 2, 0);
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_signers() {
        let mut scenario = setup_proposal_scenario();
        
        // SIGNER1 signs
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        // SIGNER2 signs
        ts::next_tx(&mut scenario, SIGNER2);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            assert!(treasury::get_signature_count(&proposal) == 3, 0);
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ENotSigner)]
    fun test_sign_proposal_non_signer() {
        let mut scenario = setup_proposal_scenario();
        
        ts::next_tx(&mut scenario, NON_SIGNER);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EAlreadySigned)]
    fun test_sign_proposal_twice() {
        let mut scenario = setup_proposal_scenario();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            // ADMIN already signed during creation, try again
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    // =================== Policy Tests ===================

    #[test]
    fun test_set_category_limit() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            let limit = treasury::new_spending_limit(
                100000,  // daily
                500000,  // weekly
                2000000, // monthly
                50000    // per tx cap
            );
            
            treasury::set_category_limit(
                &mut treasury,
                &admin_cap,
                string::utf8(b"Marketing"),
                limit
            );
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_whitelist_management() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            
            treasury::add_whitelist(&mut treasury, &admin_cap, RECIPIENT);
            treasury::add_whitelist(&mut treasury, &admin_cap, SIGNER1);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }

    // =================== Helper Functions ===================

    fun setup_proposal_scenario(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Create treasury
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Test Treasury"),
                signers,
                3,
                3600000,
                1000,
                ts::ctx(&mut scenario)
            );
            let coin = coin::mint_for_testing<SUI>(1000000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create proposal
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                create_transaction(RECIPIENT, 100000, string::utf8(b"Operations")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"Test proposal"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        scenario
    }
}