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
pragma circom 2.1.4;

include "../lib/check-positive.circom";
include "../lib/check-hashes.circom";
include "../lib/check-sum.circom";
include "../lib/encrypt-outputs.circom";
include "../node_modules/circomlib/circuits/babyjub.circom";

// This version of the circuit performs the following operations:
// - derive the sender's public key from the sender's private key
// - check the input and output commitments match the expected hashes
// - check the input and output values sum to the same amount
// - perform encryption of the receiver's output UTXO value and salt
template Zeto(nInputs, nOutputs) {
  signal input inputCommitments[nInputs];
  signal input inputValues[nInputs];
  signal input inputSalts[nInputs];
  // must be properly hashed and trimmed to be compatible with the BabyJub curve.
  // Reference: https://github.com/iden3/circomlib/blob/master/test/babyjub.js#L103
  signal input inputOwnerPrivateKey;
  // an ephemeral private key that is used to generated the shared ECDH key for encryption
  signal input ecdhPrivateKey;
  signal input outputCommitments[nOutputs];
  signal input outputValues[nOutputs];
  signal input outputSalts[nOutputs];
  signal input outputOwnerPublicKeys[nOutputs][2];
  signal input encryptionNonce;

  // the output for the public key of the ephemeral private key used in generating ECDH shared key
  signal output ecdhPublicKey[2];

  // the output for the list of encrypted output UTXOs cipher texts
  signal output cipherTexts[nOutputs][4];

  // derive the sender's public key from the secret input
  // for the sender's private key. This step demonstrates
  // the sender really owns the private key for the input
  // UTXOs
  var inputOwnerPublicKey[2];
  component pub = BabyPbk();
  pub.in <== inputOwnerPrivateKey;
  inputOwnerPublicKey[0] = pub.Ax;
  inputOwnerPublicKey[1] = pub.Ay;
  var inputOwnerPublicKeys[nInputs][2];
  for (var i = 0; i < nInputs; i++) {
    inputOwnerPublicKeys[i][0] = inputOwnerPublicKey[0];
    inputOwnerPublicKeys[i][1] = inputOwnerPublicKey[1];
  }

  component checkPositives = CheckPositive(nOutputs);
  checkPositives.outputValues <== outputValues;

  component checkInputHashes = CheckHashes(nInputs);
  checkInputHashes.commitments <== inputCommitments;
  checkInputHashes.values <== inputValues;
  checkInputHashes.salts <== inputSalts;
  checkInputHashes.ownerPublicKeys <== inputOwnerPublicKeys;

  component checkOutputHashes = CheckHashes(nOutputs);
  checkOutputHashes.commitments <== outputCommitments;
  checkOutputHashes.values <== outputValues;
  checkOutputHashes.salts <== outputSalts;
  checkOutputHashes.ownerPublicKeys <== outputOwnerPublicKeys;

  component checkSum = CheckSum(nInputs, nOutputs);
  checkSum.inputValues <== inputValues;
  checkSum.outputValues <== outputValues;

  component encryptOutputs = EncryptOutputs(nOutputs);
  encryptOutputs.ecdhPrivateKey <== ecdhPrivateKey;
  encryptOutputs.encryptionNonce <== encryptionNonce;
  encryptOutputs.outputValues <== outputValues;
  encryptOutputs.outputSalts <== outputSalts;
  encryptOutputs.outputOwnerPublicKeys <== outputOwnerPublicKeys;
  
  encryptOutputs.ecdhPublicKey ==> ecdhPublicKey;
  encryptOutputs.cipherTexts ==> cipherTexts;
}
