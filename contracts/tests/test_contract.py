"""aggregator.cairo test file."""
import os

import pytest
import pytest_asyncio
from starkware.starknet.testing.starknet import Starknet
from starkware.crypto.signature.signature import (
    pedersen_hash, private_to_stark_key, sign)
from starkware.cairo.common.hash_state import compute_hash_on_elements
from starkware.starknet.utils.api_utils import cast_to_felts

from utils import (
    Signer, to_uint, add_uint, sub_uint, str_to_felt, MAX_UINT256, ZERO_ADDRESS, INVALID_UINT256,
    get_contract_def, contract_path, cached_contract, assert_revert, assert_event_emitted, uint
)

signer = Signer(999654321123456789)

oracles = [
    { 'signer': Signer(123456789987654321), 'transmitter': Signer(987654321123456789) },
    { 'signer': Signer(123456789987654322), 'transmitter': Signer(987654321123456788) },
    { 'signer': Signer(123456789987654323), 'transmitter': Signer(987654321123456787) },
    { 'signer': Signer(123456789987654324), 'transmitter': Signer(987654321123456786) },
]

@pytest_asyncio.fixture(scope='module')
async def token_factory():
    # Create a new Starknet class that simulates the StarkNet system.
    starknet = await Starknet.empty()
    owner = await starknet.deploy(
        contract_path("account.cairo"),
        constructor_calldata=[signer.public_key]
    )

    token = await starknet.deploy(
        contract_path("token.cairo"),
        constructor_calldata=[
            str_to_felt("LINK Token"),
            str_to_felt("LINK"),
            18,
            *uint(1000),
            owner.contract_address,
            owner.contract_address
        ]
    )
    return starknet, token, owner

# @pytest.mark.asyncio
# async def test_ownership(token_factory):
#     """Test constructor method."""
#     starknet, token, owner = token_factory    

#     # Deploy the contract.
#     contract = await starknet.deploy(
#         source=contract_path("aggregator.cairo"),
#         constructor_calldata=[
#             owner.contract_address,
#             token.contract_address,
#             0,
#             1000000000,
#             0, # TODO: billing AC
#             8, # decimals
#             str_to_felt("ETH/BTC")
#         ]
#     )

#     # # Invoke increase_balance() twice.
#     # await contract.increase_balance(amount=10).invoke()
#     # await contract.increase_balance(amount=20).invoke()

#     # Check the result of owner().
#     execution_info = await contract.owner().call()
#     assert execution_info.result == (owner.contract_address,)

async def setup(token_factory):
    starknet, token, owner = token_factory    

    # Deploy the contract.
    min_answer = -10
    max_answer = 1000000000

    contract = await starknet.deploy(
        source=contract_path("aggregator.cairo"),
        constructor_calldata=cast_to_felts([
            owner.contract_address,
            token.contract_address,
            *cast_to_felts(values=[
                min_answer,
                max_answer
            ]),
            0, # TODO: billing AC
            8, # decimals
            str_to_felt("ETH/BTC")
        ])
    )

    # Deploy an account for each oracle
    for oracle in oracles:
        oracle['account'] = await starknet.deploy(
            contract_path("account.cairo"),
            constructor_calldata=[oracle['transmitter'].public_key]
        )
    
    # Call set_config

    f = 1
    # onchain_config = []
    onchain_config = 1
    offchain_config_version = 2
    offchain_config = [1]
    
    # TODO: need to call via owner
    execution_info = await contract.set_config(
        oracles=[(
            oracle['signer'].public_key,
            oracle['account'].contract_address
        ) for oracle in oracles],
        # TODO: dict was supposed to be ok but it asks for a tuple
        # oracles=[{
        #     'signer': oracle['signer'].public_key,
        #     'transmitter': oracle['transmitter'].public_key
        # } for oracle in oracles],
        f=f,
        onchain_config=onchain_config,
        offchain_config_version=2,
        offchain_config=offchain_config
    ).invoke()

    digest = execution_info.result.digest

    return {
        "starknet": starknet,
        "token": token,
        "owner": owner,
        "contract": contract,
        "f": f,
        "digest": digest,
        "oracles": oracles
    }


@pytest.mark.asyncio
async def test_transmit(token_factory):
    """Test transmit method."""
    env = await setup(token_factory)
    print(f"digest = {env['digest']}")

    oracle = env["oracles"][0]

    n = env["f"] + 1
    
    def transmit(
        epoch_and_round, # TODO: split into two values
        answer
    ):
        # TODO:
        observation_timestamp = 1
        extra_hash = 1
        juels_per_fee_coin = 1
        report_context = [env["digest"], epoch_and_round, extra_hash]
        # int.from_bytes(report_context, "big"),

        l = len(env["oracles"])
        observers = bytes([i for i in range(l)])
        observations = [answer for _ in range(l)]
    

        raw_report = [
            observation_timestamp,
            int.from_bytes(observers, "big"),
            len(observations),
            *cast_to_felts(observations), # convert negative numbers to valid felts
            juels_per_fee_coin,
        ]
    
        msg = compute_hash_on_elements([
            *report_context,
            *raw_report
        ])

        signatures = []
    
        # TODO: test with duplicate signers
        # for o in oracles[:n]:
        #     oracle = oracles[0]

        for oracle in env["oracles"][:n]:
            # Sign with a single oracle
            sig_r, sig_s = sign(msg_hash=msg, priv_key=oracle['signer'].private_key)
    
            signature = [
                sig_r, # r
                sig_s, # s
                oracle['signer'].public_key  # public_key
            ]
            signatures.extend(signature)

        calldata = [
            *report_context,
            *raw_report,
            n, # len signatures
            *signatures # TODO: how to convert objects to calldata? using array for now
        ]
    
        print(calldata)
    
        return oracle['transmitter'].send_transaction(
            oracle['account'],
            env["contract"].contract_address,
            'transmit',
            calldata
        )

    await transmit(epoch_and_round=1, answer=99)
    await transmit(epoch_and_round=2, answer=-1)
    
