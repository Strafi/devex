pragma ton-solidity >=0.38.2;
pragma AbiHeader time;
pragma AbiHeader pubkey;
pragma AbiHeader expire;

//================================================================================
//
import "./DnsRecordBase.sol";

//================================================================================
//
contract DnsRecord is DnsRecordBase
{
    //========================================
    //
    function calculateDomainAddress(string domainName) public view override returns (address, TvmCell)
    {
        TvmCell stateInit = tvm.buildStateInit({
            contr: DnsRecord,
            varInit: {
                _domainName: domainName,
                _domainCode: _domainCode
            },
            code: _domainCode
        });

        return (address(tvm.hash(stateInit)), stateInit);
    }
    
    //========================================
    //
    /// @dev we still need address and pubkey here in constructor, because root level domains are registerd right away;
    //
    constructor(uint256 ownerID) public 
    {
        // _validateDomainName() is very expensive, can't do anything without tvm.accept() first;
        // Be sure that you use a valid "_domainName", otherwise you will loose your Crystals;        
        tvm.accept();

        _nameIsValid = _validateDomainName(_domainName);
        require(_nameIsValid, ERROR_DOMAIN_NAME_NOT_VALID);

       (string[] segments, string parentName) = _parseDomainName(_domainName);
        _whoisInfo.segmentsCount              = uint8(segments.length);
        _whoisInfo.domainName                 = _domainName;
        _whoisInfo.parentDomainName           = parentName;
       (_whoisInfo.parentDomainAddress, )     = calculateDomainAddress(parentName);
        _whoisInfo.registrationType           = REG_TYPE.DENY; //sanity
        _whoisInfo.dtCreated                  = now;
        _whoisInfo.dtExpires                  = 0; // sanity
        
        // Registering a new domain is the same as claiming the expired from this point:
        _claimExpired(ownerID);
    }

    //========================================
    //
    /// @dev dangerous function;
    //
    function releaseDomain() external override onlyOwner notExpired
    {
        if(msg.pubkey() != 0) { tvm.accept(); }

        _changeOwner(0);  
        _whoisInfo.dtExpires = 0;

        emit domainReleased(now);

        if(msg.value > 0) { msg.sender.transfer(0, true, 64); }
    }

    //========================================
    //
    function _claimExpired(uint256 newOwnerID) internal 
    {
        // if it is a ROOT domain name
        if(_whoisInfo.segmentsCount == 1) 
        {
            // Root domains won't need approval, internal callback right away
            _callbackOnRegistrationRequest(REG_RESULT.APPROVED, newOwnerID);
        }
    }
    
    function claimExpired(uint256 newOwnerID) public override Expired NameIsValid
    {
        require(msg.pubkey() == 0 && msg.sender != addressZero && msg.value > 0, ERROR_REQUIRE_INTERNAL_MESSAGE_WITH_VALUE);

        // reset ownership first
        _changeOwner(0);        
        _claimExpired(newOwnerID);

        if(_whoisInfo.segmentsCount > 1)
        {
            _sendRegistrationRequest(newOwnerID);
        }
    }

    //========================================
    //
    function _sendRegistrationRequest(uint256 newOwnerID) internal view
    {
        IDnsRecord(_whoisInfo.parentDomainAddress).receiveRegistrationRequest{value: 0, callback: IDnsRecord.callbackOnRegistrationRequest, flag: 64}(_domainName, newOwnerID, msg.sender);
    }
    
    //========================================
    //
    function receiveRegistrationRequest(string domainName, uint256 ownerID, address payerAddress) external responsible override returns (REG_RESULT, uint256, address)
    {
        //========================================
        // 1. Check if it is really my subdomain;
        (, string parentName) = _parseDomainName(domainName);
        require(parentName == _whoisInfo.domainName, ERROR_MESSAGE_SENDER_IS_NOT_MY_SUBDOMAIN);

        // 2. Check if the request came from domain itself;
        (address addr, ) = calculateDomainAddress(domainName);
        require(addr == msg.sender, ERROR_MESSAGE_SENDER_IS_NOT_VALID);

        //========================================
        // REG_TYPE.MONEY has a custom flow;
        if(_whoisInfo.registrationType == REG_TYPE.MONEY && msg.value >= _whoisInfo.subdomainRegPrice)
        {
            tvm.rawReserve(address(this).balance - msg.value + _whoisInfo.subdomainRegPrice, 0);

            _whoisInfo.subdomainRegAccepted += 1;
            _whoisInfo.totalFeesCollected   += _whoisInfo.subdomainRegPrice;
            emit newSubdomainRegistered(now, domainName, _whoisInfo.subdomainRegPrice);
            
            return{value: 0, flag: 128}(REG_RESULT.APPROVED, ownerID, payerAddress); // we don't return ANY change in this case
        }

        //========================================
        // General flow;
        REG_RESULT result;
             if(_whoisInfo.registrationType == REG_TYPE.FFA)    {    result = REG_RESULT.APPROVED;    }
        else if(_whoisInfo.registrationType == REG_TYPE.DENY)   {    result = REG_RESULT.DENIED;      }
        else if(_whoisInfo.registrationType == REG_TYPE.MONEY)
        {
            // If we are here that means "REG_TYPE.MONEY" custom flow was unsuccessful;
            result = REG_RESULT.NOT_ENOUGH_MONEY;
        }
        else if(_whoisInfo.registrationType == REG_TYPE.OWNER)
        {
            bool ownerCalled = (ownerID == _whoisInfo.ownerID);
            result = (ownerCalled ? REG_RESULT.APPROVED : REG_RESULT.DENIED);
        }

        // Statistics
        if(result == REG_RESULT.APPROVED)
        {
            // 1.
            _whoisInfo.subdomainRegAccepted += 1;
            emit newSubdomainRegistered(now, domainName, 0);
        }
        else if(result == REG_RESULT.DENIED)
        {
            _whoisInfo.subdomainRegDenied += 1;
        }

        // Return the change
        return{value: 0, flag: 64}(result, ownerID, payerAddress);
    }
    
    //========================================
    //
    function _callbackOnRegistrationRequest(REG_RESULT result, uint256 ownerID) internal
    {
        emit registrationResult(now, result, ownerID);
        _whoisInfo.lastRegResult = result;
        
        if(result == REG_RESULT.APPROVED)
        {
            _whoisInfo.ownerID         = ownerID;
            _whoisInfo.dtExpires       = (now + ninetyDays);
            _whoisInfo.totalOwnersNum += 1;
        }
        else if(result == REG_RESULT.DENIED || result == REG_RESULT.NOT_ENOUGH_MONEY)
        {
            // Domain ownership is reset
            _whoisInfo.ownerID   = 0;
            _whoisInfo.dtExpires = 0;
        }
    }

    //========================================
    //
    function callbackOnRegistrationRequest(REG_RESULT result, uint256 ownerID, address payerAddress) external override onlyRoot
    {
        // TODO: do we need "tvm.accept()" here?
        // TODO: do we need to test non-root attempts to send message here?
        tvm.accept();

        // We can't move this to a modifier because if it's there parent domain will get a Bounce message back with all the
        // TONs that need to be returned to original caller;
        // 
        // NOTE: but "onlyRoot" is still a modifier, because if anyone else is sending us a message, we should Bounce it;
        if(isExpired())
        {
            _callbackOnRegistrationRequest(result, ownerID);
        }

        // return change to payer if applicable
        if(msg.value > 0 && payerAddress != addressZero)
        {
            payerAddress.transfer(0, true, 64);
        }
    }
}

//================================================================================
//
