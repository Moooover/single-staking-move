module SimpleFarm::Staking {
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::timestamp;

    const EPOOL_NOT_INITIALIZED: u64 = 0;
    const EINVALID_DEDICATED_INITIALIZER: u64 = 4;
    const EINVALID_OWNER: u64 = 5;
    const EUSER_DIDNT_STAKE: u64 = 1;
    const EINVALID_BALANCE: u64 = 2;
    const EINVALID_VALUE: u64 = 3;
    const EINVALID_COIN: u64 = 6;

    const ACC_PRECISION: u128 = 100000000000;
    const TOKEN_PER_SECOND: u64 = 100;

    struct StakeInfo<phantom CoinType> has key {
        amount: u64,
        reward_amount: u128,
        reward_debt: u128
    }

    struct PoolInfo<phantom CoinType> has key {
        owner_addr: address,
        acc_reward_per_share: u64,
        token_per_second: u64,
        last_reward_time: u64,
        staker_count: u64,
        staked_coins: coin::Coin<CoinType>
    }

    public entry fun initialize<CoinType>(initializer: &signer) {
        let owner_addr = signer::address_of(initializer);
        assert!(owner_addr == @SimpleFarm, EINVALID_DEDICATED_INITIALIZER);

        let current_time = timestamp::now_seconds();
        move_to<PoolInfo<CoinType>>(initializer, PoolInfo<CoinType> {
            owner_addr,
            acc_reward_per_share: 0,
            token_per_second: TOKEN_PER_SECOND,
            last_reward_time: current_time,
            staker_count: 0,
            staked_coins: coin::zero<CoinType>()
        });
    }

    public entry fun transfer_ownership<CoinType>(current_owner: &signer, new_owner_addr: address, pool_addr: address) acquires PoolInfo {
        assert!(exists<PoolInfo<CoinType>>(pool_addr), EPOOL_NOT_INITIALIZED);
        let pool_info = borrow_global_mut<PoolInfo<CoinType>>(pool_addr);

        let current_owner_addr = signer::address_of(current_owner);
        assert!(pool_info.owner_addr == current_owner_addr, EINVALID_OWNER);

        pool_info.owner_addr = new_owner_addr;
    }

    public entry fun stake<CoinType>(staker: &signer, amount: u64, pool_addr: address) acquires PoolInfo, StakeInfo {
        assert!(exists<PoolInfo<CoinType>>(pool_addr), EPOOL_NOT_INITIALIZED);

        let pool_info = borrow_global_mut<PoolInfo<CoinType>>(pool_addr);
        update_pool<CoinType>(pool_info);

        let staker_addr = signer::address_of(staker);
        if (!exists<StakeInfo<CoinType>>(staker_addr)) {
            move_to<StakeInfo<CoinType>>(staker, StakeInfo {
                amount,
                reward_amount: 0,
                reward_debt: 0
            });
            pool_info.staker_count = pool_info.staker_count + 1;
        } else {
            let stake_info = borrow_global_mut<StakeInfo<CoinType>>(staker_addr);
            update_reward_amount<CoinType>(stake_info, pool_info);
            stake_info.amount = stake_info.amount + amount;
            calculate_reward_debt<CoinType>(stake_info, pool_info);
        };
      
        let withdraw_coin = coin::withdraw<CoinType>(staker, amount);
        coin::merge<CoinType>(&mut pool_info.staked_coins, withdraw_coin);
    }

    public entry fun unstake<CoinType>(unstaker: &signer, amount: u64, pool_addr: address) acquires PoolInfo, StakeInfo {
        assert!(exists<PoolInfo<CoinType>>(pool_addr), EPOOL_NOT_INITIALIZED);

        let unstaker_addr = signer::address_of(unstaker);
        assert!(exists<StakeInfo<CoinType>>(unstaker_addr), EUSER_DIDNT_STAKE);
        
        let pool_info = borrow_global_mut<PoolInfo<CoinType>>(pool_addr);
        update_pool<CoinType>(pool_info);

        let stake_info = borrow_global_mut<StakeInfo<CoinType>>(unstaker_addr);
        assert!(amount <= stake_info.amount, EINVALID_VALUE);
        update_reward_amount<CoinType>(stake_info, pool_info);
        stake_info.amount = stake_info.amount - amount;
        calculate_reward_debt<CoinType>(stake_info, pool_info);
        
        let withdraw_coin = coin::extract<CoinType>(&mut pool_info.staked_coins, stake_info.amount);
        coin::deposit<CoinType>(unstaker_addr, withdraw_coin);
    }
/*
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
*/
    fun update_pool<CoinType>(pool_info: &mut PoolInfo<CoinType>) {
        let current_time = timestamp::now_seconds();
        let passed_seconds = current_time - pool_info.last_reward_time;
        let reward_per_share = 0;
        let pool_total_amount = coin::value(&pool_info.staked_coins);
        if (pool_total_amount != 0)
            reward_per_share = (pool_info.token_per_second as u128) * (passed_seconds as u128) * ACC_PRECISION / (pool_total_amount as u128);
        pool_info.acc_reward_per_share = pool_info.acc_reward_per_share + (reward_per_share as u64);
        pool_info.last_reward_time = current_time;
    }

    fun update_reward_amount<CoinType>(stake_info: &mut StakeInfo<CoinType>, pool_info: &PoolInfo<CoinType>) {
        let pending_reward = (stake_info.amount as u128)
            * (pool_info.acc_reward_per_share as u128)
            / ACC_PRECISION
            - stake_info.reward_debt;
        stake_info.reward_amount = stake_info.reward_amount + pending_reward;
    }

    fun calculate_reward_debt<CoinType>(stake_info: &mut StakeInfo<CoinType>, pool_info: &PoolInfo<CoinType>) {
        stake_info.reward_debt = (stake_info.amount as u128) * (pool_info.acc_reward_per_share as u128) / ACC_PRECISION
    }

    #[test_only]
    struct LpCoin {}

    #[test_only]
    use aptos_framework::managed_coin;

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
