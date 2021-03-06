pragma solidity ^0.4.24;

import "./AddressSet/AddressSet.sol";


contract SignatureVerifier {
    // define the Ethereum prefix for signing a message of length 32
    bytes private prefix = "\x19Ethereum Signed Message:\n32";

    // checks if the provided (v, r, s) signature of messageHash was created by the private key associated with _address
    function isSigned(address _address, bytes32 messageHash, uint8 v, bytes32 r, bytes32 s) public view returns (bool) {
        return _isSigned(_address, messageHash, v, r, s) || _isSignedPrefixed(_address, messageHash, v, r, s);
    }

    // checks unprefixed signatures
    function _isSigned(address _address, bytes32 messageHash, uint8 v, bytes32 r, bytes32 s)
        private pure returns (bool)
    {
        return ecrecover(messageHash, v, r, s) == _address;
    }

    // checks prefixed signatures
    function _isSignedPrefixed(address _address, bytes32 messageHash, uint8 v, bytes32 r, bytes32 s)
        private view returns (bool)
    {
        return _isSigned(_address, keccak256(abi.encodePacked(prefix, messageHash)), v, r, s);
    }
}


contract IdentityRegistry is SignatureVerifier {
    // bind address library
    using AddressSet for AddressSet.Set;

    // define identity data structure and mappings
    struct Identity {
        address recoveryAddress;
        AddressSet.Set associatedAddresses;
        AddressSet.Set providers;
        AddressSet.Set resolvers;
    }

    uint public nextEIN = 1;
    mapping (uint => Identity) private identityDirectory;
    mapping (address => uint) private associatedAddressDirectory;

    // define data structures required for recovery and, in dire circumstances, poison pills
    uint public maxAssociatedAddresses = 50;
    uint public recoveryTimeout = 2 weeks;
    uint public signatureTimeout = 1 weeks;

    struct RecoveryAddressChange {
        uint timestamp;
        address oldRecoveryAddress;
    }
    mapping (uint => RecoveryAddressChange) private recoveryAddressChangeLogs;

    struct RecoveredChange {
        uint timestamp;
        bytes32 hashedOldAssociatedAddresses;
    }
    mapping (uint => RecoveredChange) private recoveredChangeLogs;


    // checks whether a given identity exists (does not throw)
    function identityExists(uint ein) public view returns (bool) {
        return ein != 0 && ein < nextEIN;
    }

    // checks whether a given identity exists
    modifier _identityExists(uint ein) {
        require(identityExists(ein), "The identity does not exist.");
        _;
    }

    // checks whether a given address has an identity (does not throw)
    function hasIdentity(address _address) public view returns (bool) {
        return identityExists(associatedAddressDirectory[_address]);
    }

    // enforces that a given address has/does not have an identity
    modifier _hasIdentity(address _address, bool check) {
        require(hasIdentity(_address) == check, "The passed address has/does not have an identity.");
        _;
    }

    // gets the ein of an address (throws if the address doesn't have an ein)
    function getEIN(address _address) public view _hasIdentity(_address, true) returns (uint ein) {
        return associatedAddressDirectory[_address];
    }

    // checks whether a given identity has an address (does not throw)
    function isAddressFor(uint ein, address _address) public view returns (bool) {
        if (!identityExists(ein)) return false;
        return identityDirectory[ein].associatedAddresses.contains(_address);
    }

    // checks whether a given identity has a provider (does not throw)
    function isProviderFor(uint ein, address provider) public view returns (bool) {
        if (!identityExists(ein)) return false;
        return identityDirectory[ein].providers.contains(provider);
    }

    // enforces that an identity has a provider
    modifier _isProviderFor(uint ein, address provider) {
        require(isProviderFor(ein, provider), "The identity has not set the passed provider.");
        _;
    }

    // checks whether a given identity has a resolver (does not throw)
    function isResolverFor(uint ein, address resolver) public view returns (bool) {
        if (!identityExists(ein)) return false;
        return identityDirectory[ein].resolvers.contains(resolver);
    }

    // functions to read identity values (throws if the passed EIN does not exist)
    function getDetails(uint ein) public view _identityExists(ein)
        returns (address recoveryAddress, address[] associatedAddresses, address[] providers, address[] resolvers)
    {
        Identity storage _identity = identityDirectory[ein];
        return (
            _identity.recoveryAddress,
            _identity.associatedAddresses.members,
            _identity.providers.members,
            _identity.resolvers.members
        );
    }

    // checks whether or not a passed timestamp is within/not within the timeout period
    function isRecoveryTimedOut(uint timestamp) private view returns (bool) {
        return block.timestamp > timestamp + recoveryTimeout; // solium-disable-line security/no-block-members
    }

    modifier ensureSignatureTimeValid(uint timestamp) {
        require(
            // solium-disable-next-line security/no-block-members
            block.timestamp >= timestamp && timestamp + signatureTimeout > block.timestamp,
            "Timestamp is not valid."
        );
        _;
    }

    // mints a new identity for the msg.sender
    function mintIdentity(address recoveryAddress, address provider, address[] resolvers) public returns (uint ein)
    {
        return mintIdentity(recoveryAddress, msg.sender, provider, resolvers, false);
    }

    // mints a new identity for the passed address (with the msg.sender as the implicit provider)
    function mintIdentityDelegated(
        address recoveryAddress, address associatedAddress, address[] resolvers,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public ensureSignatureTimeValid(timestamp) returns (uint ein)
    {
        require(
            isSigned(
                associatedAddress,
                keccak256(
                    abi.encodePacked(
                        "I authorize an Identity to be minted on my behalf.",
                        address(this), recoveryAddress, associatedAddress, msg.sender, resolvers, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        return mintIdentity(recoveryAddress, associatedAddress, msg.sender, resolvers, true);
    }

    // common logic for all identity minting
    function mintIdentity(
        address recoveryAddress,
        address associatedAddress,
        address provider,
        address[] resolvers,
        bool delegated
    )
        private _hasIdentity(associatedAddress, false) returns (uint)
    {
        uint ein = nextEIN++;

        // set identity variables
        Identity storage _identity = identityDirectory[ein];
        _identity.recoveryAddress = recoveryAddress;
        _identity.associatedAddresses.insert(associatedAddress);
        _identity.providers.insert(provider);
        for (uint i; i < resolvers.length; i++) {
            _identity.resolvers.insert(resolvers[i]);
        }

        // set reverse address lookup
        associatedAddressDirectory[associatedAddress] = ein;

        emit IdentityMinted(ein, recoveryAddress, associatedAddress, provider, resolvers, delegated);

        return ein;
    }

    // allow providers to add addresses
    function addAddress(
        address approvingAddress,
        address addressToAdd,
        uint8[2] v, bytes32[2] r, bytes32[2] s, uint[2] timestamp
    )
        public _hasIdentity(addressToAdd, false)
        ensureSignatureTimeValid(timestamp[0]) ensureSignatureTimeValid(timestamp[1])
    {
        uint ein = getEIN(approvingAddress);
        require(
            identityDirectory[ein].associatedAddresses.length() <= maxAssociatedAddresses,
            "Cannot add too many addresses."
        );

        require(
            isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        "I authorize adding this address to my Identity.",
                        address(this), ein, addressToAdd, timestamp[0]
                    )
                ),
                v[0], r[0], s[0]
            ),
            "Permission denied from approving address."
        );
        require(
            isSigned(
                addressToAdd,
                keccak256(
                    abi.encodePacked(
                        "I authorize being added to this Identity.", address(this), ein, addressToAdd, timestamp[1]
                    )
                ),
                v[1], r[1], s[1]
            ),
            "Permission denied from address to add."
        );

        identityDirectory[ein].associatedAddresses.insert(addressToAdd);
        associatedAddressDirectory[addressToAdd] = ein;

        emit AddressAdded(ein, addressToAdd, approvingAddress, msg.sender);
    }

    // allow providers to remove addresses
    function removeAddress(address addressToRemove, uint8 v, bytes32 r, bytes32 s, uint timestamp)
        public ensureSignatureTimeValid(timestamp)
    {
        uint ein = getEIN(addressToRemove);

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "I authorize removing this address from my Identity.", address(this), ein, addressToRemove, timestamp
            )
        );
        require(isSigned(addressToRemove, messageHash, v, r, s), "Permission denied.");

        identityDirectory[ein].associatedAddresses.remove(addressToRemove);
        delete associatedAddressDirectory[addressToRemove];

        emit AddressRemoved(ein, addressToRemove, msg.sender);
    }

    // allows addresses associated with an identity to add providers
    function addProviders(address[] providers) public {
        addProviders(getEIN(msg.sender), providers, false);
    }

    // allows providers to add other providers for addresses
    function addProviders(uint ein, address[] providers) public _isProviderFor(ein, msg.sender) {
        addProviders(ein, providers, true);
    }

    // common functionality to add providers
    function addProviders(uint ein, address[] providers, bool delegated) private {
        Identity storage _identity = identityDirectory[ein];
        for (uint i; i < providers.length; i++) {
            _identity.providers.insert(providers[i]);
            emit ProviderAdded(ein, providers[i], delegated);
        }
    }

    // allows addresses associated with an identity to remove providers
    function removeProviders(address[] providers) public {
        removeProviders(getEIN(msg.sender), providers, false);
    }

    // allows providers to remove other providers for addresses
    function removeProviders(uint ein, address[] providers) public _isProviderFor(ein, msg.sender) {
        removeProviders(ein, providers, true);
    }

    // common functionality to remove providers
    function removeProviders(uint ein, address[] providers, bool delegated) private {
        Identity storage _identity = identityDirectory[ein];
        for (uint i; i < providers.length; i++) {
            _identity.providers.remove(providers[i]);
            emit ProviderRemoved(ein, providers[i], delegated);
        }
    }

    // allow providers to add resolvers
    function addResolvers(uint ein, address[] resolvers) public _isProviderFor(ein, msg.sender) {
        Identity storage _identity = identityDirectory[ein];
        for (uint i; i < resolvers.length; i++) {
            _identity.resolvers.insert(resolvers[i]);
            emit ResolverAdded(ein, resolvers[i], msg.sender);
        }
    }

    // allow providers to remove resolvers
    function removeResolvers(uint ein, address[] resolvers) public _isProviderFor(ein, msg.sender) {
        Identity storage _identity = identityDirectory[ein];
        for (uint i; i < resolvers.length; i++) {
            _identity.resolvers.remove(resolvers[i]);
            emit ResolverRemoved(ein, resolvers[i], msg.sender);
        }
    }


    // initiate a change in recovery address
    function initiateRecoveryAddressChange(uint ein, address newRecoveryAddress)
        public _isProviderFor(ein, msg.sender)
    {
        require(
            isRecoveryTimedOut(recoveryAddressChangeLogs[ein].timestamp),
            "Pending change of recovery address has not timed out."
        );

        // log the old recovery address
        Identity storage _identity = identityDirectory[ein];
        address oldRecoveryAddress = _identity.recoveryAddress;
         // solium-disable-next-line security/no-block-members
        recoveryAddressChangeLogs[ein] = RecoveryAddressChange(block.timestamp, oldRecoveryAddress);

        // make the change
        _identity.recoveryAddress = newRecoveryAddress;

        emit RecoveryAddressChangeInitiated(ein, oldRecoveryAddress, newRecoveryAddress);
    }

    // initiate recovery, only callable by the current recovery address, or the one changed within the past 2 weeks
    function triggerRecovery(uint ein, address newAssociatedAddress, uint8 v, bytes32 r, bytes32 s, uint timestamp)
        public _identityExists(ein) _hasIdentity(newAssociatedAddress, false) ensureSignatureTimeValid(timestamp)
    {
        require(
            isRecoveryTimedOut(recoveredChangeLogs[ein].timestamp),
            "It has not been long enough since the last recovery."
        );

        // ensure the sender is the recovery address/old recovery address if there's been a recent change
        Identity storage _identity = identityDirectory[ein];
        RecoveryAddressChange storage recoveryAddressChange = recoveryAddressChangeLogs[ein];
        if (isRecoveryTimedOut(recoveryAddressChange.timestamp)) {
            require(
                msg.sender == _identity.recoveryAddress, "Only the current recovery address can initiate a recovery."
            );
        } else {
            require(
                msg.sender == recoveryAddressChange.oldRecoveryAddress,
                "Only the recently removed recovery address can initiate a recovery."
            );
        }

        require(
            isSigned(
                newAssociatedAddress,
                keccak256(
                    abi.encodePacked(
                        "I authorize being added to this Identity via recovery.",
                        address(this), ein, newAssociatedAddress, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        emit RecoveryTriggered(ein, msg.sender, _identity.associatedAddresses.members, newAssociatedAddress);

        // log the old associated addresses to unlock the poison pill
        bytes32 hashedOldAssociatedAddresses = keccak256(abi.encodePacked(_identity.associatedAddresses.members));
        // solium-disable-next-line security/no-block-members
        recoveredChangeLogs[ein] = RecoveredChange(block.timestamp, hashedOldAssociatedAddresses);

        // remove identity data, and add the new address as the sole associated address
        clearAllIdentityData(_identity, false);
        _identity.recoveryAddress = msg.sender;
        _identity.associatedAddresses.insert(newAssociatedAddress);
        associatedAddressDirectory[newAssociatedAddress] = ein;
    }

    // allows addresses recently removed by recovery to permanently disable the identity they were removed from
    function triggerPoisonPill(uint ein, address[] firstChunk, address[] lastChunk, bool clearResolvers)
        public _identityExists(ein)
    {
        RecoveredChange storage log = recoveredChangeLogs[ein];
        require(!isRecoveryTimedOut(log.timestamp), "No addresses have recently been removed from a recovery.");

        // ensure that the msg.sender was an old associated address for the referenced identity
        address[1] memory middleChunk = [msg.sender];
        require(
            keccak256(abi.encodePacked(firstChunk, middleChunk, lastChunk)) == log.hashedOldAssociatedAddresses,
            "Cannot activate the poison pill from an address that was not recently removed via recover."
        );

        // poison the identity
        Identity storage _identity = identityDirectory[ein];
        emit Poisoned(ein, _identity.recoveryAddress, msg.sender, clearResolvers);
        clearAllIdentityData(_identity, clearResolvers);
    }

    // removes all associated addresses, providers, and optionally resolvers from an identity
    function clearAllIdentityData(Identity storage identity, bool clearResolvers) private {
        address[] storage associatedAddresses = identity.associatedAddresses.members;
        for (uint i; i < associatedAddresses.length; i++) {
            delete associatedAddressDirectory[associatedAddresses[i]];
        }
        delete identity.associatedAddresses;
        delete identity.providers;
        if (clearResolvers) delete identity.resolvers;
    }


    // define events
    event IdentityMinted(
        uint indexed ein,
        address recoveryAddress,
        address associatedAddress,
        address provider,
        address[] resolvers,
        bool delegated
    );
    event AddressAdded(uint indexed ein, address addedAddress, address approvingAddress, address provider);
    event AddressRemoved(uint indexed ein, address removedAddress, address provider);
    event ProviderAdded(uint indexed ein, address provider, bool delegated);
    event ProviderRemoved(uint indexed ein, address provider, bool delegated);
    event ResolverAdded(uint indexed ein, address resolvers, address provider);
    event ResolverRemoved(uint indexed ein, address resolvers, address provider);
    event RecoveryAddressChangeInitiated(uint indexed ein, address oldRecoveryAddress, address newRecoveryAddress);
    event RecoveryTriggered(
        uint indexed ein, address recoveryAddress, address[] oldAssociatedAddresses, address newAssociatedAddress
    );
    event Poisoned(uint indexed ein, address recoveryAddress, address poisoner, bool resolversCleared);
}
