module SimpleFarm::Staking {
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::managed_coin;
    use aptos_framework::timestamp;

    use aptos_std::type_info;

    const EPOOL_NOT_INITIALIZED: u64 = 0;
    const EINVALID_DEDICATED_INITIALIZER: u64 = 4;
    const EINVALID_OWNER: u64 = 5;
    const EUSER_DIDNT_STAKE: u64 = 1;
    const EINVALID_BALANCE: u64 = 2;
    const EINVALID_VALUE: u64 = 3;
    const EINVALID_COIN: u64 = 6;

    const ACC_PRECISION: u128 = 100000000000;
    const TOKEN_PER_SECOND: u64 = 100;

    struct StakeInfo has key, store {
        amount: u64,
        reward_amount: u128,
        reward_debt: u128,
    }

    struct PoolInfo has key, store {
        owner_addr: address,
        amount: u128,
        acc_reward_per_share: u64,
        token_per_second: u64,
        last_reward_time: u64,
        staker_count: u64,
        resource_cap: account::SignerCapability,
    }

    public entry fun initialize<CoinType>(initializer: &signer, seeds: vector<u8>) {
        let owner_addr = signer::address_of(initializer);
        // assert!(owner_addr == @Initializer, EINVALID_DEDICATED_INITIALIZER);
        let (pool, pool_signer_cap) = account::create_resource_account(initializer, seeds);

        let current_time = timestamp::now_seconds();
        move_to<PoolInfo>(&pool, PoolInfo {
            owner_addr,
            amount: 0,
            acc_reward_per_share: 0,
            token_per_second: TOKEN_PER_SECOND,
            resource_cap: pool_signer_cap,
            last_reward_time: current_time.
            staker_count: 0,
        });
        coin::register<CoinType>(&pool);
    }

    public entry fun transfer_ownership(current_owner: &signer, new_owner_addr: address, pool_addr: address) acquires PoolInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);
        let pool_info = borrow_global_mut<PoolInfo>(pool_addr);

        let current_owner_addr = signer::address_of(current_owner);
        assert!(pool_info.owner_addr == current_owner_addr, EINVALID_OWNER);

        pool_info.owner_addr = new_owner_addr;
    }

    public entry fun stake<CoinType>(staker: &signer, amount: u64, pool_addr: address) acquires PoolInfo, StakeInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);

        let pool_info = borrow_global_mut<PoolInfo>(pool_addr);
        update_pool(pool_info);

        let staker_addr = signer::address_of(staker);
        if (!exists<StakeInfo>(staker_addr)) {
            move_to<StakeInfo>(staker, StakeInfo {
                amount,
                reward_amount: 0,
                reward_debt: 0
            });
            pool_info.staker_count = pool_info.staker_count + 1;
        } else {
            let stake_info = borrow_global_mut<StakeInfo>(staker_addr);
            update_reward_amount(stake_info, pool_info);
            stake_info.amount = stake_info.amount + amount;
            calculate_reward_debt(stake_info, pool_info);
        };
        
        pool_info.amount = pool_info.amount + (amount as u128);

        coin::transfer<CoinType>(staker, pool_addr, amount);
    }

    public entry fun unstake<CoinType>(unstaker: &signer, amount: u64, pool_addr: address) acquires PoolInfo, StakeInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);

        let unstaker_addr = signer::address_of(unstaker);
        assert!(exists<StakeInfo>(unstaker_addr), EUSER_DIDNT_STAKE);
        
        let pool_info = borrow_global_mut<PoolInfo>(pool_addr);
        update_pool(pool_info);

        let stake_info = borrow_global_mut<StakeInfo>(unstaker_addr);
        assert!(amount <= stake_info.amount, EINVALID_VALUE);
        update_reward_amount(stake_info, pool_info);
        stake_info.amount = stake_info.amount - amount;
        calculate_reward_debt(stake_info, pool_info);
        
        pool_info.amount = pool_info.amount - (amount as u128);

        let pool_account_from_cap = account::create_signer_with_capability(&pool_info.resource_cap);
        coin::transfer<CoinType>(&pool_account_from_cap, unstaker_addr, amount);
    }

    public entry fun harvest<CoinType>(staker: &signer, pool_addr: address) acquires PoolInfo, StakeInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);
        check_reward_coin_type<CoinType>();

        let staker_addr = signer::address_of(staker);
        assert!(exists<StakeInfo>(staker_addr), EUSER_DIDNT_STAKE);

        if (!coin::is_account_registered<CoinType>(staker_addr)) {
            managed_coin::register<CoinType>(staker);
        };

        let pool_info = borrow_global_mut<PoolInfo>(pool_addr);
        update_pool(pool_info);

        let stake_info = borrow_global_mut<StakeInfo>(staker_addr);
        update_reward_amount(stake_info, pool_info);
        
        let pool_account_from_cap = account::create_signer_with_capability(&pool_info.resource_cap);
        coin::transfer<CoinType>(&pool_account_from_cap, staker_addr, (stake_info.reward_amount as u64));

        stake_info.reward_amount = 0;
        calculate_reward_debt(stake_info, pool_info);
    }

    public entry fun fund_reward<CoinType>(owner: &signer, amount: u64, pool_addr: address) acquires PoolInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);
        check_reward_coin_type<CoinType>();
        if (!coin::is_account_registered<CoinType>(pool_addr)) {
            let pool_info = borrow_global_mut<PoolInfo>(pool_addr);
            let pool_account_from_cap = account::create_signer_with_capability(&pool_info.resource_cap);
            managed_coin::register<CoinType>(&pool_account_from_cap);
        };
        coin::transfer<CoinType>(owner, pool_addr, amount);
    }

    public entry fun withdraw_reward<CoinType>(owner: &signer, amount: u64, pool_addr: address) acquires PoolInfo {
        assert!(exists<PoolInfo>(pool_addr), EPOOL_NOT_INITIALIZED);
        let pool_info = borrow_global<PoolInfo>(pool_addr);

        let owner_addr = signer::address_of(owner);
        assert!(pool_info.owner_addr == owner_addr, EINVALID_OWNER);

        check_reward_coin_type<CoinType>();
        let pool_info = borrow_global_mut<PoolInfo>(pool_addr);        
        let pool_account_from_cap = account::create_signer_with_capability(&pool_info.resource_cap);
        coin::transfer<CoinType>(&pool_account_from_cap, owner_addr, amount);
    }

    fun update_pool(pool_info: &mut PoolInfo) {
        let current_time = timestamp::now_seconds();
        let passed_seconds = current_time - pool_info.last_reward_time;
        let reward_per_share = 0;
        if (pool_info.amount != 0)
            reward_per_share = (pool_info.token_per_second as u128) * (passed_seconds as u128) * ACC_PRECISION / pool_info.amount;
        pool_info.acc_reward_per_share = pool_info.acc_reward_per_share + (reward_per_share as u64);
        pool_info.last_reward_time = current_time;
    }

    fun update_reward_amount(stake_info: &mut StakeInfo, pool_info: &PoolInfo) {
        let pending_reward = (stake_info.amount as u128)
            * (pool_info.acc_reward_per_share as u128)
            / ACC_PRECISION
            - stake_info.reward_debt;
        stake_info.reward_amount = stake_info.reward_amount + pending_reward;
    }

    fun calculate_reward_debt(stake_info: &mut StakeInfo, pool_info: &PoolInfo) {
        stake_info.reward_debt = (stake_info.amount as u128) * (pool_info.acc_reward_per_share as u128) / ACC_PRECISION
    }

    fun check_reward_coin_type<CoinType>() {
        assert!(@MoonCoinType == type_info::account_address(&type_info::type_of<CoinType>()), EINVALID_COIN);
    }

    fun check_stake_coin_type<CoinType>() {
        //assert!(@MoonCoinType == type_info::account_address(&type_info::type_of<CoinType>()), EINVALID_COIN);
    }

    #[test_only]
    struct LpCoin {}

    #[test(alice = @0x1, stakeModule = @SimpleFarm)]
    public entry fun can_initialize(alice: signer, stakeModule: signer){
        let alice_addr = signer::address_of(&alice);
        // initialize token
        managed_coin::initialize<LpCoin>(&stakeModule, b"Liquidity Provision Coin", b"LP", 9, false);

        // check alice's token balance
        coin::register_for_test<LpCoin>(&alice);
        managed_coin::mint<LpCoin>(&stakeModule, alice_addr, 10000);
        assert!(coin::balance<LpCoin>(alice_addr) == 10000, EINVALID_BALANCE);

        // initialize pool
        initialize<LpCoin>(&stakeModule, b"wsol-pool");

        // check pool balance
        let pool_addr = account::create_resource_address(&@SimpleFarm, b"wsol-pool");
        assert!(coin::balance<LpCoin>(pool_addr) == 0, EINVALID_BALANCE);

        // alice stake 1000 to pool
        stake<LpCoin>(&alice, 1000, pool_addr);

        // check stake result
        assert!(coin::balance<LpCoin>(alice_addr) == 9000, EINVALID_BALANCE);
        assert!(coin::balance<LpCoin>(pool_addr) == 1000, EINVALID_BALANCE);

        // alice unstake all from pool
        unstake<LpCoin>(&alice, 500, pool_addr);
        assert!(coin::balance<LpCoin>(alice_addr) == 9500, EINVALID_BALANCE);
        assert!(coin::balance<LpCoin>(pool_addr) == 500, EINVALID_BALANCE);

    }
}
