module my_game::my_game {
    use sui::tx_context::sender;
    use sui::vec_map::{VecMap, Self};
    use sui::package;
    use two_coins::siphonelee_coin::{Self, SIPHONELEE_COIN};
    use sui::coin;
    use sui::coin::{Coin, TreasuryCap};
    use sui::sui::SUI;
    use sui::balance;
    use sui::clock::{Self, Clock};
    use sui::bcs::{Self};
    use sui::random::{Self, Random};
    use sui::hash::blake2b256;

    const ENotEnoughChips: u64 = 1;
    const EZeroBalance: u64 = 2;
    const EGameInProgress: u64 = 3;
    const EGameNotInProgress: u64 = 4;
    const EGameTooShort: u64 = 5;
    const ENotEnoughBet: u64 = 6;
    const EWrongCommisionFeePoint: u64 = 7;

    public struct MY_GAME has drop {}

    public struct MyGameCap has key {
        id: UID
    }

    public struct Dealer has key {
        id: UID,

        // 手续费点，单位0.01%
        commission_fee_point: u16,
        // 每局游戏最小时长，以秒为单位
        min_time_span: u64,
        // 每局游戏最小bet
        min_bet: u64,

        // 是否一局游戏正在进行中
        game_on: bool,
        // 本局游戏开始时间，以秒为单位
        game_start_time: u64,
        
        coins_pool: balance::Balance<SUI>,

        bettor_big: VecMap<address, u64>,
        bettor_small: VecMap<address, u64>,
    }

    fun init(otw: MY_GAME, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
        // Creating and sending the HouseCap object to the sender.
        let cap = MyGameCap {
            id: object::new(ctx)
        };

        transfer::transfer(cap, ctx.sender());
    }

    public entry fun init_dealer(cap: MyGameCap, treasury_cap: &mut TreasuryCap<SIPHONELEE_COIN>, chips_amount: u64, 
                            commission_fee_point: u16, min_time_span: u64, min_bet: u64, ctx: &mut TxContext) {
        assert!(commission_fee_point < 10000, EWrongCommisionFeePoint);
        let MyGameCap { id } = cap;
        object::delete(id);
        
        // initial mint for chips
        siphonelee_coin::mint(treasury_cap, chips_amount, sender(ctx), ctx);

        let dealer = Dealer {
            id: object::new(ctx),
            commission_fee_point,
            min_time_span,
            min_bet,

            game_on: false,
            game_start_time: 0,

            coins_pool: balance::zero(),

            bettor_big: vec_map::empty(),
            bettor_small: vec_map::empty(),
        };
        transfer::share_object(dealer);
    }

    // 1:1兑换 sui -> chip
    public entry fun coin_in(dealer: &mut Dealer, chips_pool: &mut Coin<SIPHONELEE_COIN>, coin: Coin<SUI>, ctx: &mut TxContext) {
        let balance = coin.balance().value();  
        assert!(balance > 0, EZeroBalance);
        assert!(chips_pool.value() >= balance, ENotEnoughChips);

        // 发回兑换的chips
        let c = coin::take(chips_pool.balance_mut(), balance, ctx);
        transfer::public_transfer(c, sender(ctx));

        // 更新资金池
        dealer.coins_pool.join(coin.into_balance());
    }

    // 1:1兑换 chip -> sui
    public entry fun coin_out(dealer: &mut Dealer, chips_pool: &mut Coin<SIPHONELEE_COIN>, chips: Coin<SIPHONELEE_COIN>, ctx: &mut TxContext) {
        let balance = chips.balance().value();
        assert!(balance > 0, EZeroBalance);
        assert!(dealer.coins_pool.value() >= balance, ENotEnoughChips);

        // 发回兑换的sui
        transfer::public_transfer(coin::from_balance(dealer.coins_pool.split(balance), ctx), 
                                sender(ctx));
        // 更新chips池
        chips_pool.join(chips);
    }

    // 开始游戏
    public entry fun start_game(dealer: &mut Dealer, clock: &Clock, _ctx: &mut TxContext) {
        assert!(!dealer.game_on, EGameInProgress);
        dealer.game_on = true;
        dealer.game_start_time = clock::timestamp_ms(clock);
    }

    // 大/小押/注
    public entry fun bet(dealer: &mut Dealer, chips_pool: &mut Coin<SIPHONELEE_COIN>, bet_for_big: bool, chips: Coin<SIPHONELEE_COIN>, ctx: &mut TxContext) {
        assert!(dealer.game_on, EGameNotInProgress);

        let balance = chips.balance().value();
        assert!(balance >= dealer.min_bet, ENotEnoughBet);

        let addr = sender(ctx);
        if (bet_for_big) {
            if (dealer.bettor_big.try_get(&addr).is_some()) {
                let bet = dealer.bettor_big.get_mut(&addr);
                *bet = *bet + balance;
            } else {
                dealer.bettor_big.insert(addr, balance);
            }
        } else {
            if (dealer.bettor_small.try_get(&addr).is_some()) {
                let bet = dealer.bettor_small.get_mut(&addr);
                *bet = *bet + balance;
            } else {
                dealer.bettor_small.insert(addr, balance);
            }
        };

        // 更新chips池
        chips_pool.join(chips);
    }

    // 拼接随机串，目的是防止被提前预测。包括几个部分：
    // - sui链上随机数
    // - sui链上时间戳
    // - sui epoch
    // - bet信息（参与的地址数量和金额）
    fun get_seed_array(dealer: &mut Dealer, ts: u64, epoch: u64, seed: u64, ctx: &mut TxContext): vector<u8> {
        let mut seed_array = object::id_bytes(dealer);

        let mut b = bcs::to_bytes(&ts);
        seed_array.append(b);

        b = bcs::to_bytes(&epoch);
        seed_array.append(b);

        b = bcs::to_bytes(&seed);
        seed_array.append(b);

        let (bet_num_big, total_bets_big, bet_num_small, total_bets_small) = get_bet_amounts(dealer, ctx);
        let b1 = bcs::to_bytes(&bet_num_big);
        let b2 = bcs::to_bytes(&total_bets_big);
        let b3 = bcs::to_bytes(&bet_num_small);
        let b4 = bcs::to_bytes(&total_bets_small);

        seed_array.append(b1);
        seed_array.append(b2);
        seed_array.append(b3);
        seed_array.append(b4);

        seed_array
    }

    // 获取大/小结果
    fun get_game_verdict(dealer: &mut Dealer, ts: u64, seed: u64, ctx: &mut TxContext): bool {
        let seed_array = get_seed_array(dealer, ts, tx_context::epoch(ctx), seed, ctx);
        let hashed_beacon = blake2b256(&seed_array);
        let first_byte = hashed_beacon[0];
        first_byte % 2 == 1
    }

    // 扣除手续费后返还coin
    fun reward(chips_pool: &mut Coin<SIPHONELEE_COIN>, winners: &VecMap<address, u64>,
                winner_total_bets: u64, total_win: u64, commission_fee_point: u16, ctx: &mut TxContext) {
        let mut n = 0;
        while (n < winners.size()) {
            let (addr, bet) = winners.get_entry_by_idx(n);
            let award = (*bet as u128 + (total_win as u128 * (*bet as u128)) / (winner_total_bets as u128)) * (10000u128 - (commission_fee_point as u128)) / 10000;

            let c = coin::take(chips_pool.balance_mut(), award as u64, ctx);
            transfer::public_transfer(c, *addr);

            n = n + 1;
        };
    }

    // 游戏清算
    fun game_clearance(dealer: &mut Dealer, chips_pool: &mut Coin<SIPHONELEE_COIN>, ts: u64, random_seed: u64, ctx: &mut TxContext) {
        let (bettor_cnt_big, total_bets_big, bettor_cnt_small, total_bets_small) = get_bet_amounts(dealer, ctx);
        if (bettor_cnt_big == 0 || bettor_cnt_small == 0) {
            // 如果只bet了大或者小一边，则游戏失败，coin原路退还，只收取手续费
            if (bettor_cnt_big == 0) {
                reward(chips_pool, &dealer.bettor_small, total_bets_small, 0, dealer.commission_fee_point, ctx);
            } else {
                reward(chips_pool, &dealer.bettor_big, total_bets_big, 0, dealer.commission_fee_point, ctx);
            }
        } else {
            // 根据随机数确定赢的一方
            if (get_game_verdict(dealer, ts, random_seed, ctx)) {
                // 大/赢
                reward(chips_pool, &dealer.bettor_big, total_bets_big, total_bets_small, dealer.commission_fee_point, ctx);
            } else {
                // 小/赢
                reward(chips_pool, &dealer.bettor_small, total_bets_small, total_bets_big, dealer.commission_fee_point, ctx);
            }
        }
    }

    // 结束游戏
    #[allow(lint(public_random))]
    public entry fun end_game(dealer: &mut Dealer, chips_pool: &mut Coin<SIPHONELEE_COIN>, clock: &Clock, r: &Random, ctx: &mut TxContext) {
        assert!(dealer.game_on, EGameNotInProgress);
        let now = clock::timestamp_ms(clock);
        let tm_span = now - dealer.game_start_time;
        assert!(tm_span/1000 >= dealer.min_time_span, EGameTooShort);
        
        let mut generator = random::new_generator(r, ctx);
        let random_seed = random::generate_u64(&mut generator);

        game_clearance(dealer, chips_pool, now, random_seed, ctx);

        // reset status for next game
        dealer.game_on = false;
        dealer.bettor_big = vec_map::empty();
        dealer.bettor_small = vec_map::empty();        
    }

    /////////////////  返回各种状态  //////////////////////
    public entry fun is_game_on(dealer: &mut Dealer, _ctx: &mut TxContext): bool {
        dealer.game_on
    }

    public fun get_total_bets(v: &VecMap<address, u64>): u64 {
        let mut total_bets = 0;
        let mut n = 0;
        while (n < v.size()) {
            let (_, v) = v.get_entry_by_idx(n);
            total_bets = total_bets + *v;

            n = n + 1;
        };

        total_bets        
    }

    public entry fun get_bet_amounts(dealer: &mut Dealer, _ctx: &mut TxContext): (u64, u64, u64, u64) {
        let total_bets_big = get_total_bets(&dealer.bettor_big);
        let total_bets_small = get_total_bets(&dealer.bettor_small);

        (dealer.bettor_big.size(), total_bets_big, dealer.bettor_small.size(), total_bets_small)
    }

    ////////////////////////////////////////////////////
    /////////////////  UNIT TEST  //////////////////////
    ////////////////////////////////////////////////////
    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use sui::test_scenario::{next_tx, ctx};

    #[test_only]
    const EWrongValue: u64 = 1;
    #[test_only]
    const EWrongAmout: u64 = 1;

    #[test_only]
    const AIRDRO_AMOUNT: u64 = 100000;
    #[test_only]
    const COIN_IN_AMOUNT: u64 = 2000;
    #[test_only]
    const COIN_IN_AMOUNT_MORE: u64 = 3000;
    #[test_only]
    const FEE_BP: u16 = 100;

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(MY_GAME {}, ctx)
    }

    #[test]
    fun test_dealer() {
        let dealer = @0xA;
        let mut scenario = test_scenario::begin(dealer);
 
        {  
            siphonelee_coin::test_init(scenario.ctx());
            test_init(scenario.ctx());
        };

        next_tx(&mut scenario, dealer);
        {
            let game_cap = test_scenario::take_from_sender<MyGameCap>(&scenario);
            let mut treasury_cap = test_scenario::take_from_sender<TreasuryCap<SIPHONELEE_COIN>>(&scenario);

            init_dealer(game_cap, &mut treasury_cap, 1000000, FEE_BP, 300, 100, scenario.ctx());

            test_scenario::return_to_sender(&scenario, treasury_cap);
        };

        next_tx(&mut scenario, dealer);
        {
            let dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips_pool = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            assert!(dealer.commission_fee_point == 100, EWrongValue);
            assert!(dealer.min_time_span == 300, EWrongValue);
            assert!(dealer.min_bet == 100, EWrongValue);
            assert!(chips_pool.value() == 1000000, EWrongValue);

            test_scenario::return_shared(dealer);
            test_scenario::return_to_sender(&scenario, chips_pool);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_coin_in_coin_out() {
        let dealer = @0xA;
        let alice = @0xB;

        let mut scenario = test_scenario::begin(dealer);
 
        {  
            siphonelee_coin::test_init(scenario.ctx());
            test_init(scenario.ctx());
        };

        next_tx(&mut scenario, dealer);
        {
            let game_cap = test_scenario::take_from_sender<MyGameCap>(&scenario);
            let mut treasury_cap = test_scenario::take_from_sender<TreasuryCap<SIPHONELEE_COIN>>(&scenario);

            init_dealer(game_cap, &mut treasury_cap, 1000000, FEE_BP, 300, 100, scenario.ctx());

            test_scenario::return_to_sender(&scenario, treasury_cap);
        };

        let mut chips_pool;
        next_tx(&mut scenario, dealer);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            chips_pool = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            // airdrop some sui first
            dealer.coins_pool.join(balance::create_for_testing(AIRDRO_AMOUNT));
            // transfer some sui to alice
            let c1 = coin::take(&mut dealer.coins_pool, COIN_IN_AMOUNT, scenario.ctx());
            transfer::public_transfer(c1, alice);

            test_scenario::return_shared(dealer);
        };
        
        next_tx(&mut scenario, alice);
        {
            // coin in
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let coin = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            coin_in(&mut dealer, &mut chips_pool, coin, scenario.ctx());
            test_scenario::return_shared(dealer);
        };

        next_tx(&mut scenario, alice);
        {
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            let v = chips.value();
            assert!(v == COIN_IN_AMOUNT, EWrongAmout);

            // coin out
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            coin_out(&mut dealer, &mut chips_pool, chips, scenario.ctx());
            test_scenario::return_shared(dealer);
        };

        next_tx(&mut scenario, alice);
        {
            let coins = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            let v = coins.value();
            assert!(v == COIN_IN_AMOUNT, EWrongAmout);

            transfer::public_transfer(coins, alice);
        };

        next_tx(&mut scenario, dealer);
        {
            test_scenario::return_to_sender(&scenario, chips_pool);
        };

        test_scenario::end(scenario);
    }     

    #[test]
    fun test_bet_return() {
        let dealer = @0xA;
        let alice = @0xB;
        let bob = @0xC;
        let charlie = @0xD;
        let daisy = @0xE;
        let dummy_address = @0xCAFE;

        let mut scenario = test_scenario::begin(dealer);
 
        {  
            siphonelee_coin::test_init(scenario.ctx());
            test_init(scenario.ctx());
        };

        next_tx(&mut scenario, dealer);
        {
            let game_cap = test_scenario::take_from_sender<MyGameCap>(&scenario);
            let mut treasury_cap = test_scenario::take_from_sender<TreasuryCap<SIPHONELEE_COIN>>(&scenario);

            init_dealer(game_cap, &mut treasury_cap, 1000000, FEE_BP, 300, 100, scenario.ctx());

            test_scenario::return_to_sender(&scenario, treasury_cap);
        };

        let mut chips_pool;
        next_tx(&mut scenario, dealer);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            chips_pool = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            // airdrop some sui first
            dealer.coins_pool.join(balance::create_for_testing(AIRDRO_AMOUNT));
            // transfer some sui to alice/bob/charlie/daisy
            let c1 = coin::take(&mut dealer.coins_pool, COIN_IN_AMOUNT, scenario.ctx());
            transfer::public_transfer(c1, alice);
            let c2 = coin::take(&mut dealer.coins_pool, COIN_IN_AMOUNT, scenario.ctx());
            transfer::public_transfer(c2, bob);
            let c3 = coin::take(&mut dealer.coins_pool, COIN_IN_AMOUNT_MORE, scenario.ctx());
            transfer::public_transfer(c3, charlie);
            let c4 = coin::take(&mut dealer.coins_pool, COIN_IN_AMOUNT_MORE, scenario.ctx());
            transfer::public_transfer(c4, daisy);

            test_scenario::return_shared(dealer);
        };

        // alice/bob/charlie/daisy coin in
        next_tx(&mut scenario, alice);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let coin = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            coin_in(&mut dealer, &mut chips_pool, coin, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, bob);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let coin = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            coin_in(&mut dealer, &mut chips_pool, coin, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, charlie);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let coin = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            coin_in(&mut dealer, &mut chips_pool, coin, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, daisy);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let coin = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            coin_in(&mut dealer, &mut chips_pool, coin, scenario.ctx());
            test_scenario::return_shared(dealer);
        };

        let mut clk = clock::create_for_testing(scenario.ctx());

        // alice/bob/charlie/daisy bet
        next_tx(&mut scenario, alice);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            start_game(&mut dealer, &clk, scenario.ctx());

            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            bet(&mut dealer, &mut chips_pool, true, chips, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, bob);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            bet(&mut dealer, &mut chips_pool, true, chips, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, charlie);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            bet(&mut dealer, &mut chips_pool, true, chips, scenario.ctx());
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, daisy);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);
            bet(&mut dealer, &mut chips_pool, true, chips, scenario.ctx());
            test_scenario::return_shared(dealer);
        };

        // add 10 minutes
        let ts = clk.timestamp_ms();
        clk.set_for_testing(ts + 10u64 * 60 * 1000);

        let mut game_ret = 0;

        let user0 = @0x0;
        let mut ts = test_scenario::begin(user0);
        random::create_for_testing(ts.ctx());

        // end game
        next_tx(&mut scenario, bob);
        {
            let mut dealer = test_scenario::take_shared<Dealer>(&scenario);
            let r = test_scenario::take_shared<Random>(&scenario);
            end_game(&mut dealer, &mut chips_pool, &clk, &r, scenario.ctx());
            test_scenario::return_shared(dealer);
            test_scenario::return_shared(r);
        };

        // alice/bob/charlie/daisy get bet results
        next_tx(&mut scenario, alice);
        {
            let dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            let v = chips.value();
            game_ret = game_ret + v;
            assert!(v == 0 || v == COIN_IN_AMOUNT * (10000u64 - (FEE_BP as u64)) / 10000, EWrongAmout);

            transfer::public_transfer(chips, dummy_address);
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, bob);
        {
            let dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            let v = chips.value();
            game_ret = game_ret + v;
            assert!(v == 0 || v == COIN_IN_AMOUNT * (10000u64 - (FEE_BP as u64)) / 10000, EWrongAmout);

            transfer::public_transfer(chips, dummy_address);
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, charlie);
        {
            let dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            let v = chips.value();
            game_ret = game_ret + v;
            assert!(v == 0 || v == COIN_IN_AMOUNT_MORE * (10000u64 - (FEE_BP as u64)) / 10000, EWrongAmout);

            transfer::public_transfer(chips, dummy_address);
            test_scenario::return_shared(dealer);
        };
        next_tx(&mut scenario, daisy);
        {
            let dealer = test_scenario::take_shared<Dealer>(&scenario);
            let chips = test_scenario::take_from_sender<Coin<SIPHONELEE_COIN>>(&scenario);

            let v = chips.value();
            game_ret = game_ret + v;
            assert!(v == 0 || v == COIN_IN_AMOUNT_MORE * (10000u64 - (FEE_BP as u64)) / 10000, EWrongAmout);

            transfer::public_transfer(chips, dummy_address);
            test_scenario::return_shared(dealer);
        };
        
        assert!(game_ret == (2 * COIN_IN_AMOUNT + 2 * COIN_IN_AMOUNT_MORE) * (10000u64 - (FEE_BP as u64)) / 10000, EWrongAmout);

        next_tx(&mut scenario, dealer);
        {
            test_scenario::return_to_sender(&scenario, chips_pool);
        };

        ts.end();
        clock::destroy_for_testing(clk);
        test_scenario::end(scenario);
    }   
}