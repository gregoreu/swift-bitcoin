import Foundation

/// An error while executing a bitcoin script.
enum ScriptError: Error {
    case malformedIfElseEndIf,
         missingStackArgument,
         missingAltStackArgument,
         missingMultiSigArgument,
         unparsableScript,
         nonPushOnlyScript,
         invalidStackOperation,
         unparsableOperation,
         unknownOperation,
         disabledOperation,
         numberOverflow,
         negativeZero, /// BIP62 rule 4
         zeroPaddedNumber, /// BIP62 rule 4
         nonMinimalPush, /// BIP62 rule 3
         nonMinimalBoolean,
         nonLowSSignature,
         invalidPublicKeyEncoding,
         invalidSignatureEncoding,
         undefinedSighashType,
         missingDummyValue,
         dummyValueNotNull,
         invalidLockTimeArgument,
         lockTimeHeightEarly,
         lockTimeSecondsEarly,
         invalidLockTime,
         invalidSequenceArgument,
         sequenceHeightEarly,
         sequenceSecondsEarly,
         invalidSequence,
         inputSequenceFinal,
         scriptSigNotEmpty,
         falseReturned,
         scriptSigTooManyPushes,
         uncleanStack,
         wrongWitnessScriptHash,
         witnessProgramWrongLength,
         disallowedWitnessVersion,
         nonConstantScript,
         signatureNotEmpty,
         tapscriptCheckMultiSigDisabled,
         invalidSchnorrSignature,
         invalidSchnorrSignatureFormat,
         invalidTapscriptControlBlock,
         invalidTaprootPublicKey,
         invalidTaprootTweak,
         missingTaprootWitness,
         disallowedTaprootVersion,
         disallowedOpSuccess,
         disallowsPublicKeyType,
         sigopBudgetExceeded,
         initialStackLimitExceeded,
         stacksLimitExceeded,
         initialStackMaxElementSizeExceeded,
         stacksMaxElementSizeExceeded,
         stackMaxElementSizeExceeded,
         scriptSizeLimitExceeded,
         operationsLimitExceeded,
         maxPublicKeysExceeded,
         emptyPublicKey,
         emptySchnorrSignature,
         disallowedNoOp,
         invalidCheckSigAddArgument,
         minimumTransactionVersionRequired,
         sequenceLockTimeDisabled
}
