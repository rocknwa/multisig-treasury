#[test_only]
module multisig_treasury::integration_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::{Self};
    use sui::sui::SUI;
    use multisig_treasury::treasury::{
        Self, 
        Treasury, 
        Proposal,
    };
    use std::string::{Self};

    const ADMIN: address = @0xA;
    const SIGNER1: address = @0xB;
    const SIGNER2: address = @0xC;
    const SIGNER3: address = @0xD;
    const SIGNER4: address = @0xE;
    const RECIPIENT1: address = @0xF1;
    const RECIPIENT2: address = @0xF2;
    const RECIPIENT3: address = @0xF3;

    fun create_signers(): vector<address> {
        let mut signers = vector::empty();
        vector::push_back(&mut signers, ADMIN);
        vector::push_back(&mut signers, SIGNER1);
        vector::push_back(&mut signers, SIGNER2);
        vector::push_back(&mut signers, SIGNER3);
        vector::push_back(&mut signers, SIGNER4);
        signers
    }

    // =================== End-to-End Workflow Tests ===================

    #[test]
    fun test_complete_proposal_lifecycle() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // 1. Create treasury
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Complete Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            // Fund treasury
            let coin = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // 2. Create proposal
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 1_000_000_000, string::utf8(b"Operations")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"Complete lifecycle test"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        // 3. Collect signatures
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            assert!(treasury::get_signature_count(&proposal) == 2, 0);
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::next_tx(&mut scenario, SIGNER2);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            assert!(treasury::get_signature_count(&proposal) == 3, 0);
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        // 4. Execute (timelock is very short)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            treasury::execute_proposal(&mut treasury, &mut proposal, ts::ctx(&mut scenario));
            assert!(treasury::is_executed(&proposal), 0);
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_batch_transaction_execution() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Batch Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            let coin = coin::mint_for_testing<SUI>(100_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create batch proposal with 5 transactions
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 1_000_000_000, string::utf8(b"Payroll")));
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT2, 2_000_000_000, string::utf8(b"Payroll")));
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT3, 1_500_000_000, string::utf8(b"Payroll")));
            vector::push_back(&mut transactions, 
                treasury::new_transaction(SIGNER1, 3_000_000_000, string::utf8(b"Payroll")));
            vector::push_back(&mut transactions, 
                treasury::new_transaction(SIGNER2, 2_500_000_000, string::utf8(b"Payroll")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Payroll"),
                string::utf8(b"Monthly payroll - 5 payments"),
                ts::ctx(&mut scenario)
            );
            
            // Verify total amount
            assert!(treasury::get_proposal_amount(&proposal) == 10_000_000_000, 0);
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        // Sign and execute
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::next_tx(&mut scenario, SIGNER2);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            treasury::sign_proposal(&treasury, &mut proposal, ts::ctx(&mut scenario));
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::next_tx(&mut scenario, SIGNER3);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            
            let initial_balance = treasury::get_balance(&treasury);
            treasury::execute_proposal(&mut treasury, &mut proposal, ts::ctx(&mut scenario));
            let final_balance = treasury::get_balance(&treasury);
            
            // Verify all transactions executed
            assert!(initial_balance - final_balance == 10_000_000_000, 0);
            assert!(treasury::is_executed(&proposal), 1);
            
            ts::return_shared(treasury);
            ts::return_shared(proposal);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_concurrent_proposals() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Concurrent Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            let coin = coin::mint_for_testing<SUI>(50_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create first proposal
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 5_000_000_000, string::utf8(b"Marketing")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Marketing"),
                string::utf8(b"Proposal 1"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        // Create second proposal
        ts::next_tx(&mut scenario, SIGNER1);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT2, 3_000_000_000, string::utf8(b"Development")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Development"),
                string::utf8(b"Proposal 2"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        // Create third proposal
        ts::next_tx(&mut scenario, SIGNER2);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT3, 2_000_000_000, string::utf8(b"Operations")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"Proposal 3"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        // All proposals exist independently
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            // Verify treasury still has full balance
            assert!(treasury::get_balance(&treasury) == 50_000_000_000, 0);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_policy_enforcement_with_limits() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup with strict limits
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Policy Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            // Set strict category limit
            let limit = treasury::new_spending_limit(
                5_000_000_000,  // 5 SUI daily
                20_000_000_000, // 20 SUI weekly
                80_000_000_000, // 80 SUI monthly
                2_000_000_000   // 2 SUI per tx
            );
            
            treasury::set_category_limit(
                &mut treasury,
                &admin_cap,
                string::utf8(b"Marketing"),
                limit
            );
            
            let coin = coin::mint_for_testing<SUI>(100_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create valid proposal within limits
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 1_500_000_000, string::utf8(b"Marketing")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Marketing"),
                string::utf8(b"Valid within limits"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EPolicyViolation)]
    fun test_policy_enforcement_exceeds_limit() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup with strict global limits
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Policy Test Treasury"),
                signers,
                3,
                0,
                1000,
                ts::ctx(&mut scenario)
            );
            
            // Set global limit with per-tx cap
            let global_limit = treasury::new_spending_limit(
                10_000_000_000,  // 10 SUI daily
                50_000_000_000,  // 50 SUI weekly
                200_000_000_000, // 200 SUI monthly
                2_000_000_000    // 2 SUI per tx cap - this will be violated
            );
            
            treasury::set_global_limit(
                &mut treasury,
                &admin_cap,
                global_limit
            );
            
            let coin = coin::mint_for_testing<SUI>(100_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create proposal exceeding per-tx cap (3 SUI > 2 SUI cap)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 3_000_000_000, string::utf8(b"Marketing")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Marketing"),
                string::utf8(b"Exceeds limit"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_whitelist_enforcement() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup with whitelist
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Whitelist Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            // Add only RECIPIENT1 to whitelist
            treasury::add_whitelist(&mut treasury, &admin_cap, RECIPIENT1);
            
            let coin = coin::mint_for_testing<SUI>(100_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Create valid proposal to whitelisted address
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT1, 1_000_000_000, string::utf8(b"Operations")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"To whitelisted address"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ENotWhitelisted)]
    fun test_whitelist_rejection() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        // Setup with whitelist
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Whitelist Test Treasury"),
                signers,
                3,
                0, // zero timelock for testing
                1000,
                ts::ctx(&mut scenario)
            );
            
            treasury::add_whitelist(&mut treasury, &admin_cap, RECIPIENT1);
            
            let coin = coin::mint_for_testing<SUI>(100_000_000_000, ts::ctx(&mut scenario));
            treasury::deposit_sui(&mut treasury, coin);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        // Try to create proposal to non-whitelisted address
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut transactions = vector::empty();
            vector::push_back(&mut transactions, 
                treasury::new_transaction(RECIPIENT2, 1_000_000_000, string::utf8(b"Operations")));
            
            let proposal = treasury::create_proposal(
                &mut treasury,
                transactions,
                string::utf8(b"Operations"),
                string::utf8(b"To non-whitelisted address"),
                ts::ctx(&mut scenario)
            );
            
            transfer::public_share_object(proposal);
            ts::return_shared(treasury);
        };
        
        ts::end(scenario);
    }

    #[test]
    fun test_signer_management() {
        let mut scenario = ts::begin(ADMIN);
        let signers = create_signers();
        
        ts::next_tx(&mut scenario, ADMIN);
        {
            let (mut treasury, admin_cap) = treasury::create_treasury(
                string::utf8(b"Signer Management Test"),
                signers,
                3,
                100,
                1000,
                ts::ctx(&mut scenario)
            );
            
            // Initial count: 5 signers
            assert!(vector::length(&treasury::get_signers(&treasury)) == 5, 0);
            
            // Add new signer
            let new_signer = @0x999;
            treasury::add_signer(&mut treasury, &admin_cap, new_signer);
            assert!(vector::length(&treasury::get_signers(&treasury)) == 6, 1);
            
            // Update threshold
            treasury::update_threshold(&mut treasury, &admin_cap, 4);
            assert!(treasury::get_threshold(&treasury) == 4, 2);
            
            // Remove a signer
            treasury::remove_signer(&mut treasury, &admin_cap, new_signer);
            assert!(vector::length(&treasury::get_signers(&treasury)) == 5, 3);
            
            transfer::public_share_object(treasury);
            transfer::public_transfer(admin_cap, ADMIN);
        };
        
        ts::end(scenario);
    }
}