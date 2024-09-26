// Copyright © 2024 Kaleido, Inc.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
pragma solidity ^0.8.20;

import {IZetoEncrypted} from "./lib/interfaces/izeto_encrypted.sol";
import {Groth16Verifier_CheckHashesValue} from "./lib/verifier_check_hashes_value.sol";
import {Groth16Verifier_CheckNullifierValue} from "./lib/verifier_check_nullifier_value.sol";
import {Groth16Verifier_AnonEncNullifierKyc} from "./lib/verifier_anon_enc_nullifier_kyc.sol";
import {Groth16Verifier_AnonEncNullifierKycBatch} from "./lib/verifier_anon_enc_nullifier_kyc_batch.sol";
import {ZetoNullifier} from "./lib/zeto_nullifier.sol";
import {ZetoFungibleWithdrawWithNullifiers} from "./lib/zeto_fungible_withdraw_nullifier.sol";
import {Registry} from "./lib/registry.sol";
import {Commonlib} from "./lib/common.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

uint256 constant MAX_BATCH = 10;

/// @title A sample implementation of a Zeto based fungible token with anonymity, encryption and history masking
/// @author Kaleido, Inc.
/// @dev The proof has the following statements:
///        - each value in the output commitments must be a positive number in the range 0 ~ (2\*\*40 - 1)
///        - the sum of the nullified values match the sum of output values
///        - the hashes in the input and output match the hash(value, salt, owner public key) formula
///        - the sender possesses the private BabyJubjub key, whose public key is part of the pre-image of the input commitment hashes, which match the corresponding nullifiers
///        - the encrypted value in the input is derived from the receiver's UTXO value and encrypted with a shared secret using the ECDH protocol between the sender and receiver (this guarantees data availability for the receiver)
///        - the nullifiers represent input commitments that are included in a Sparse Merkle Tree represented by the root hash
contract Zeto_AnonEncNullifierKyc is
    IZetoEncrypted,
    ZetoNullifier,
    ZetoFungibleWithdrawWithNullifiers,
    Registry,
    UUPSUpgradeable
{
    Groth16Verifier_AnonEncNullifierKyc internal verifier;
    Groth16Verifier_AnonEncNullifierKycBatch internal batchVerifier;

    function initialize(
        address initialOwner,
        Groth16Verifier_AnonEncNullifierKyc _verifier,
        Groth16Verifier_CheckHashesValue _depositVerifier,
        Groth16Verifier_CheckNullifierValue _withdrawVerifier,
        Groth16Verifier_AnonEncNullifierKycBatch _batchVerifier
    ) public initializer {
        __Registry_init();
        __ZetoNullifier_init(initialOwner);
        __ZetoFungibleWithdrawWithNullifiers_init(
            _depositVerifier,
            _withdrawVerifier
        );
        verifier = _verifier;
        batchVerifier = _batchVerifier;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function register(uint256[2] memory publicKey) public onlyOwner {
        _register(publicKey);
    }
    /**
     * @dev the main function of the contract, which transfers values from one account (represented by Babyjubjub public keys)
     *      to one or more receiver accounts (also represented by Babyjubjub public keys). One of the two nullifiers may be zero
     *      if the transaction only needs one UTXO to be spent. Equally one of the two outputs may be zero if the transaction
     *      only needs to create one new UTXO.
     *
     * @param nullifiers Array of nullifiers that are secretly bound to UTXOs to be spent by the transaction.
     * @param outputs Array of new UTXOs to generate, for future transactions to spend.
     * @param root The root hash of the Sparse Merkle Tree that contains the nullifiers.
     * @param proof A zero knowledge proof that the submitter is authorized to spend the inputs, and
     *      that the outputs are valid in terms of obeying mass conservation rules.
     *
     * Emits a {UTXOTransferWithEncryptedValues} event.
     */
    function transfer(
        uint256[] memory nullifiers,
        uint256[] memory outputs,
        uint256 root,
        uint256 encryptionNonce,
        uint256[] memory encryptedValues,
        Commonlib.Proof calldata proof,
        bytes calldata data
    ) public returns (bool) {
        // Check and pad commitments
        (nullifiers, outputs) = checkAndPadCommitments(
            nullifiers,
            outputs,
            MAX_BATCH
        );
        require(
            validateTransactionProposal(nullifiers, outputs, root),
            "Invalid transaction proposal"
        );
        if (nullifiers.length > 2) {
            // construct the public inputs
            uint256[55] memory publicInputs;
            uint256 piIndex = 0;
            // copy the encrypted value, salt and parity bit
            for (uint256 i = 0; i < encryptedValues.length; ++i) {
                publicInputs[piIndex++] = encryptedValues[i];
            }
            // copy input commitments
            for (uint256 i = 0; i < nullifiers.length; i++) {
                publicInputs[piIndex++] = nullifiers[i];
            }

            // copy root
            publicInputs[piIndex++] = root;

            // populate enables
            for (uint256 i = 0; i < nullifiers.length; i++) {
                publicInputs[piIndex++] = (nullifiers[i] == 0) ? 0 : 1;
            }

            // copy identities root
            publicInputs[piIndex++] = getIdentitiesRoot();
            // copy output commitments
            for (uint256 i = 0; i < outputs.length; i++) {
                publicInputs[piIndex++] = outputs[i];
            }

            // copy encryption nonce
            publicInputs[piIndex++] = encryptionNonce;

            // Check the proof
            require(
                batchVerifier.verifyProof(
                    proof.pA,
                    proof.pB,
                    proof.pC,
                    publicInputs
                ),
                "Invalid proof"
            );
        } else {
            // construct the public inputs
            uint256[16] memory publicInputs;
            uint256 piIndex = 0;
            // copy the encrypted value, salt and parity bit
            for (uint256 i = 0; i < encryptedValues.length; ++i) {
                publicInputs[piIndex++] = encryptedValues[i];
            }
            // copy input commitments
            for (uint256 i = 0; i < nullifiers.length; i++) {
                publicInputs[piIndex++] = nullifiers[i];
            }

            // copy root
            publicInputs[piIndex++] = root;

            // populate enables
            for (uint256 i = 0; i < nullifiers.length; i++) {
                publicInputs[piIndex++] = (nullifiers[i] == 0) ? 0 : 1;
            }

            // copy identities root
            publicInputs[piIndex++] = getIdentitiesRoot();
            // copy output commitments
            for (uint256 i = 0; i < outputs.length; i++) {
                publicInputs[piIndex++] = outputs[i];
            }

            // copy encryption nonce
            publicInputs[piIndex++] = encryptionNonce;

            // Check the proof
            require(
                verifier.verifyProof(
                    proof.pA,
                    proof.pB,
                    proof.pC,
                    publicInputs
                ),
                "Invalid proof"
            );
        }

        // accept the transaction to consume the input UTXOs and produce new UTXOs
        processInputsAndOutputs(nullifiers, outputs);

        uint256[] memory encryptedValuesArray = new uint256[](
            encryptedValues.length
        );
        for (uint256 i = 0; i < encryptedValues.length; ++i) {
            encryptedValuesArray[i] = encryptedValues[i];
        }

        emit UTXOTransferWithEncryptedValues(
            nullifiers,
            outputs,
            encryptionNonce,
            encryptedValuesArray,
            msg.sender,
            data
        );
        return true;
    }

    // in the current design, no KYC check is performed for deposit & withdraw functions
    // this is to reduce gas fee for deposit and withdraw function
    // users that doesn't pass KYC check will not be able to participate in transfers
    // because the transfer circuit requires the input and output owners to be in the KYC list
    // Therefore, token circulation from & to parties that are not in the KYC list is prevented
    function deposit(
        uint256 amount,
        uint256 utxo,
        Commonlib.Proof calldata proof,
        bytes calldata data
    ) public {
        _deposit(amount, utxo, proof);
        uint256[] memory utxos = new uint256[](1);
        utxos[0] = utxo;
        _mint(utxos, data);
    }

    function withdraw(
        uint256 amount,
        uint256[] memory nullifiers,
        uint256 output,
        uint256 root,
        Commonlib.Proof calldata proof
    ) public {
        uint256[] memory outputs = new uint256[](nullifiers.length);
        outputs[0] = output;
        // Check and pad commitments
        (nullifiers, outputs) = checkAndPadCommitments(
            nullifiers,
            outputs,
            MAX_BATCH
        );
        validateTransactionProposal(nullifiers, outputs, root);
        _withdrawWithNullifiers(amount, nullifiers, output, root, proof);
        processInputsAndOutputs(nullifiers, outputs);
    }

    function mint(
        uint256[] memory utxos,
        bytes calldata data
    ) public onlyOwner {
        _mint(utxos, data);
    }
}
