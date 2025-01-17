use chainlink::ocr2::aggregator::Round;
use chainlink::ocr2::aggregator::{IAggregator, IAggregatorDispatcher, IAggregatorDispatcherTrait};
use starknet::ContractAddress;

// TODO: use a generic param for the round_id?
#[starknet::interface]
trait IAggregatorProxy<TContractState> {
    fn latest_round_data(self: @TContractState) -> Round;
    fn round_data(self: @TContractState, round_id: felt252) -> Round;
    fn description(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn type_and_version(self: @TContractState) -> felt252;
}

#[starknet::interface]
trait IAggregatorProxyInternal<TContractState> {
    fn propose_aggregator(ref self: TContractState, address: ContractAddress);
    fn confirm_aggregator(ref self: TContractState, address: ContractAddress);
    fn proposed_latest_round_data(self: @TContractState) -> Round;
    fn proposed_round_data(self: @TContractState, round_id: felt252) -> Round;
    fn aggregator(self: @TContractState) -> ContractAddress;
    fn phase_id(self: @TContractState) -> u128;
}

#[starknet::contract]
mod AggregatorProxy {
    use super::IAggregatorProxy;
    use super::IAggregatorDispatcher;
    use super::IAggregatorDispatcherTrait;

    use integer::u128s_from_felt252;
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;

    use starknet::ContractAddress;
    use starknet::ContractAddressIntoFelt252;
    use starknet::Felt252TryIntoContractAddress;
    use integer::Felt252TryIntoU128;
    use starknet::StorageBaseAddress;
    use starknet::SyscallResult;
    use integer::U128IntoFelt252;
    use integer::U128sFromFelt252Result;
    use starknet::storage_read_syscall;
    use starknet::storage_write_syscall;
    use starknet::storage_address_from_base_and_offset;
    use starknet::class_hash::ClassHash;

    use chainlink::ocr2::aggregator::IAggregator;
    use chainlink::ocr2::aggregator::Round;
    use chainlink::libraries::ownable::{Ownable, IOwnable};
    use chainlink::libraries::access_control::{AccessControl, IAccessController};
    use chainlink::utils::split_felt;
    use chainlink::libraries::upgradeable::{Upgradeable, IUpgradeable};

    const SHIFT: felt252 = 0x100000000000000000000000000000000;
    const MAX_ID: felt252 = 0xffffffffffffffffffffffffffffffff;

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Phase {
        id: u128,
        aggregator: ContractAddress
    }

    #[storage]
    struct Storage {
        _current_phase: Phase,
        _proposed_aggregator: ContractAddress,
        _phases: LegacyMap<u128, ContractAddress>
    }

    #[event]
    fn AggregatorProposed(current: ContractAddress, proposed: ContractAddress) {}

    #[event]
    fn AggregatorConfirmed(previous: ContractAddress, latest: ContractAddress) {}

    #[external(v0)]
    impl AggregatorProxyImpl of IAggregatorProxy<ContractState> {
        fn latest_round_data(self: @ContractState) -> Round {
            self._require_read_access();
            let phase = self._current_phase.read();
            let aggregator = IAggregatorDispatcher { contract_address: phase.aggregator };
            let round = aggregator.latest_round_data();
            Round {
                round_id: (phase.id.into() * SHIFT) + round.round_id,
                answer: round.answer,
                block_num: round.block_num,
                started_at: round.started_at,
                updated_at: round.updated_at,
            }
        }
        fn round_data(self: @ContractState, round_id: felt252) -> Round {
            self._require_read_access();
            let (phase_id, round_id) = split_felt(round_id);
            let address = self._phases.read(phase_id);
            assert(!address.is_zero(), 'aggregator address is 0');

            let aggregator = IAggregatorDispatcher { contract_address: address };
            let round = aggregator.round_data(round_id);

            Round {
                round_id: (phase_id.into() * SHIFT) + round.round_id,
                answer: round.answer,
                block_num: round.block_num,
                started_at: round.started_at,
                updated_at: round.updated_at,
            }
        }
        fn description(self: @ContractState) -> felt252 {
            self._require_read_access();
            let phase = self._current_phase.read();
            let aggregator = IAggregatorDispatcher { contract_address: phase.aggregator };
            aggregator.description()
        }

        fn decimals(self: @ContractState) -> u8 {
            self._require_read_access();
            let phase = self._current_phase.read();
            let aggregator = IAggregatorDispatcher { contract_address: phase.aggregator };
            aggregator.decimals()
        }

        fn type_and_version(self: @ContractState) -> felt252 {
            let phase = self._current_phase.read();
            let aggregator = IAggregatorDispatcher { contract_address: phase.aggregator };
            aggregator.type_and_version()
        }
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, address: ContractAddress) {
        // TODO: ownable and access control need to share owners and update when needed
        let mut ownable = Ownable::unsafe_new_contract_state();
        Ownable::constructor(ref ownable, owner);
        let mut access_control = AccessControl::unsafe_new_contract_state();
        AccessControl::constructor(ref access_control);
        self._set_aggregator(address);
    }

    // --- Ownership ---

    #[external(v0)]
    impl OwnableImpl of IOwnable<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            let state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::owner(@state)
        }

        fn proposed_owner(self: @ContractState) -> ContractAddress {
            let state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::proposed_owner(@state)
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let mut state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::transfer_ownership(ref state, new_owner)
        }

        fn accept_ownership(ref self: ContractState) {
            let mut state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::accept_ownership(ref state)
        }

        fn renounce_ownership(ref self: ContractState) {
            let mut state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::renounce_ownership(ref state)
        }
    }

    // -- Upgradeable -- 

    #[external(v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_impl: ClassHash) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            Upgradeable::upgrade(new_impl)
        }
    }


    // -- Access Control --

    #[external(v0)]
    impl AccessControllerImpl of IAccessController<ContractState> {
        fn has_access(self: @ContractState, user: ContractAddress, data: Array<felt252>) -> bool {
            let state = AccessControl::unsafe_new_contract_state();
            AccessControl::has_access(@state, user, data)
        }

        fn add_access(ref self: ContractState, user: ContractAddress) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            let mut state = AccessControl::unsafe_new_contract_state();
            AccessControl::add_access(ref state, user)
        }

        fn remove_access(ref self: ContractState, user: ContractAddress) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            let mut state = AccessControl::unsafe_new_contract_state();
            AccessControl::remove_access(ref state, user)
        }

        fn enable_access_check(ref self: ContractState) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            let mut state = AccessControl::unsafe_new_contract_state();
            AccessControl::enable_access_check(ref state)
        }

        fn disable_access_check(ref self: ContractState) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            let mut state = AccessControl::unsafe_new_contract_state();
            AccessControl::disable_access_check(ref state)
        }
    }

    //

    #[external(v0)]
    impl AggregatorProxyInternal of super::IAggregatorProxyInternal<ContractState> {
        fn propose_aggregator(ref self: ContractState, address: ContractAddress) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            assert(!address.is_zero(), 'proposed address is 0');
            self._proposed_aggregator.write(address);

            let phase = self._current_phase.read();
            AggregatorProposed(phase.aggregator, address);
        }

        fn confirm_aggregator(ref self: ContractState, address: ContractAddress) {
            let ownable = Ownable::unsafe_new_contract_state();
            Ownable::assert_only_owner(@ownable);
            assert(!address.is_zero(), 'confirm address is 0');
            let phase = self._current_phase.read();
            let previous = phase.aggregator;

            let proposed_aggregator = self._proposed_aggregator.read();
            assert(address == proposed_aggregator, 'does not match proposed address');
            self._proposed_aggregator.write(starknet::contract_address_const::<0>());
            self._set_aggregator(proposed_aggregator);

            AggregatorConfirmed(previous, address);
        }

        fn proposed_latest_round_data(self: @ContractState) -> Round {
            self._require_read_access();
            let address = self._proposed_aggregator.read();
            let aggregator = IAggregatorDispatcher { contract_address: address };
            aggregator.latest_round_data()
        }

        fn proposed_round_data(self: @ContractState, round_id: felt252) -> Round {
            self._require_read_access();
            let address = self._proposed_aggregator.read();
            let round_id128: u128 = round_id.try_into().unwrap();
            let aggregator = IAggregatorDispatcher { contract_address: address };
            aggregator.round_data(round_id128)
        }

        fn aggregator(self: @ContractState) -> ContractAddress {
            self._require_read_access();
            let phase = self._current_phase.read();
            phase.aggregator
        }

        fn phase_id(self: @ContractState) -> u128 {
            self._require_read_access();
            let phase = self._current_phase.read();
            phase.id
        }
    }

    /// Internals

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        fn _set_aggregator(ref self: ContractState, address: ContractAddress) {
            let phase = self._current_phase.read();
            let new_phase_id = phase.id + 1_u128;
            self._current_phase.write(Phase { id: new_phase_id, aggregator: address });
            self._phases.write(new_phase_id, address);
        }

        fn _require_read_access(self: @ContractState) {
            let caller = starknet::info::get_caller_address();
            let state = AccessControl::unsafe_new_contract_state();
            AccessControl::check_read_access(@state, caller);
        }
    }
}
