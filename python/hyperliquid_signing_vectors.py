"""Offline oracle for ticket 03; prints no private key or signature.

Run with the pinned SDK signing.py path. Dependencies are test-only:
msgpack==1.1.2, eth-account==0.13.7, eth-keys==0.7.0, eth-utils==5.3.1.
"""
import ast
import hashlib
import sys
from pathlib import Path

import msgpack
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak, to_hex


def main():
    source = Path(sys.argv[1]).read_bytes()
    assert hashlib.sha256(source).hexdigest() == (
        "938ec0a1f9611874b423ca946696e19a71d32d14709f521ea5d526f4398c0b85"
    )
    functions = {
        "address_to_bytes", "action_hash", "construct_phantom_agent", "l1_payload",
        "sign_l1_action", "sign_inner", "recover_agent_or_user_from_l1_action",
    }
    tree = ast.parse(source)
    module = ast.Module(body=[node for node in tree.body
                             if isinstance(node, ast.FunctionDef)
                             and node.name in functions], type_ignores=[])
    sdk = dict(msgpack=msgpack, Account=Account, encode_typed_data=encode_typed_data,
               keccak=keccak, to_hex=to_hex)
    exec(compile(module, "<hash-verified pinned SDK>", "exec"), sdk)
    action = {"type": "order", "orders": [{"a": 4, "b": True, "p": "1670.1",
              "s": "0.0147", "r": False, "t": {"limit": {"tif": "Ioc"}}}],
              "grouping": "na"}
    key = (1).to_bytes(32, "big")  # Public synthetic scalar; never a real wallet.
    wallet = Account.from_key(key)
    assert wallet.address.lower() == "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    vectors = [
        (False, None, None, "0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908",
         "eb995f6f09994a13de522ce0cc454871e81500e01de770e09d9fa6f5d2742601"),
        (True, None, None, "0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908",
         "be5eb0697b77c2acfeaa07a3d4913ae5d06489c63bfd143c5d3d66540a196c43"),
        (False, "0x" + "02" * 20, 1677777666040,
         "cbc30667a8526a0747f48910bea2245fa4d923d97449895b58de5c6df949cf30",
         "b2e767be3b6331b38893a253fcd3faf7adb9f50a3b89b0f9ebda0f98d717408c"),
    ]
    for mainnet, account, expiry, expected_hash, expected_digest in vectors:
        connection = sdk["action_hash"](action, account, 1677777606040, expiry)
        assert connection.hex() == expected_hash
        data = sdk["l1_payload"](sdk["construct_phantom_agent"](connection, mainnet))
        message = encode_typed_data(full_message=data)
        digest = keccak(b"\x19" + message.version + message.header + message.body)
        assert digest.hex() == expected_digest
        signature = sdk["sign_l1_action"](wallet, action, account, 1677777606040, expiry, mainnet)
        assert sdk["recover_agent_or_user_from_l1_action"](
            action, signature, account, 1677777606040, expiry, mainnet) == wallet.address
        if not mainnet and account is None:
            encoded = int(signature["r"], 16).to_bytes(32, "big") + int(signature["s"], 16).to_bytes(32, "big") + bytes([signature["v"]])
            assert hashlib.sha256(encoded).hexdigest() == (
                "5149cc2ecf929663bdeeaf9a1287d5220ca2bf0be091fcb662d9488aff1eb156"
            )
    order = 115792089237316195423570985008687907852837564279074904382605163141518161494337
    for scalar, digest, expected in [
        (1, bytes(32), "bf0a07f83d9bc6d8116d68d8f677816382621084a58f832d905318cef7779d0e"),
        (order - 1, bytes([255]) * 32, "ddfb99c8c43477b94e399c78cc2b29ef2201433d734e76184110ace9a027ecff"),
    ]:
        key = scalar.to_bytes(32, "big")
        result = Account._sign_hash(digest, key)
        assert Account._recover_hash(digest, vrs=(result.v, result.r, result.s)) == Account.from_key(key).address
        encoded = result.r.to_bytes(32, "big") + result.s.to_bytes(32, "big") + bytes([result.v])
        assert hashlib.sha256(encoded).hexdigest() == expected
    print("3 pinned SDK vectors and RFC6979 signature/edge oracles passed")



if __name__ == "__main__":
    main()
