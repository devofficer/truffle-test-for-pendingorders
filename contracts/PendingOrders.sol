pragma solidity ^0.7.4;

// "SPDX-License-Identifier: MIT"

import "./DSMath.sol";
import "./SafeMath.sol";
import "./IERC20.sol";
import "./Ownable.sol";
import "./ISecondaryPool.sol";

contract PendingOrders is DSMath, Ownable {

	using SafeMath for uint256;

	struct Order {
		address orderer;
		uint amount;
		bool isWhite;
		uint eventId;
		bool isPending;
	}

	uint public ordersCount;

	uint constant _maxPrice = 100 * WAD;
	uint constant _minPrice = 0;
	uint public _FEE = 1e14;
	uint _collectedFee;

	IERC20 public _collateralToken;
	ISecondaryPool public _secondaryPool;

	address public _feeWithdrawAddress;
	address public _eventContractAddress;
	address public _secondaryPoolAddress;

	mapping(uint => Order) Orders;
	mapping(address => uint[]) ordersOfUser;
	
	struct detail {
	    uint whiteAmount;
	    uint blackAmount;
	    uint whitePriceBefore;
	    uint blackPriceBefore;
	    uint whitePriceAfter;
	    uint blackPriceAfter;
	    bool isExecuted;
	}
	
	mapping(uint => detail) detailForEvent;

	event orderCreated(uint);
	event orderCanceled(uint);
	event collateralWithdrew(uint);
	event contractOwnerChanged(address);
	event secondaryPoolAddressChanged(address);
	event eventContractAddressChanged(address);
	event feeWithdrawAddressChanged(address);
	event feeWithdrew(uint);
	event feeChanged(uint);

	constructor (
		address secondaryPoolAddress,
		address collateralTokenAddress,
		address feeWithdrawAddress,
		address eventContractAddress
	) {
		require(
			secondaryPoolAddress != address(0),
			"SECONDARY POOL ADDRESS SHOULD NOT BE NULL"
		);
		require(
			collateralTokenAddress != address(0),
			"COLLATERAL TOKEN ADDRESS SHOULD NOT BE NULL"
		);
		require(
			feeWithdrawAddress != address(0),
			"FEE WITHDRAW ADDRESS SHOULD NOT BE NULL"
		);
		require(
			eventContractAddress != address(0),
			"EVENT ADDRESS SHOULD NOT BE NULL"
		);
		_secondaryPoolAddress = secondaryPoolAddress;
		_secondaryPool = ISecondaryPool(_secondaryPoolAddress);
		_collateralToken = IERC20(collateralTokenAddress);
		_feeWithdrawAddress = feeWithdrawAddress;
		_eventContractAddress = eventContractAddress;
	}

	modifier onlyEventContract {
        require(
            msg.sender == _eventContractAddress,
            "CALLER SHOULD BE EVENT CONTRACT"
        );
        _;
    }

    function createOrder(uint _amount, bool _isWhite, uint _eventId) external returns(uint) {
    	require(
			_collateralToken.balanceOf(msg.sender) >= _amount,
			"NOT ENOUGH COLLATERAL IN USER'S ACCOUNT"
		);		
		ordersCount++;
		Orders[ordersCount] = Order(
			msg.sender,
			_amount,
			_isWhite,
			_eventId,
			true
		);
		_isWhite
			? detailForEvent[_eventId].whiteAmount = detailForEvent[_eventId].whiteAmount.add(_amount)
			: detailForEvent[_eventId].blackAmount = detailForEvent[_eventId].blackAmount.add(_amount);
			
		ordersOfUser[msg.sender].push(ordersCount);

		_collateralToken.transferFrom(msg.sender, address(this), _amount);
		emit orderCreated(ordersCount);
		return ordersCount;
    }

    function cancelOrder(uint _orderId) external {
        Order memory _Order = Orders[_orderId];
    	require(
    		_Order.isPending,
			"ORDER HAS ALREADY BEEN CANCELED"
		);
		require(
			msg.sender == _Order.orderer,
			"NOT ALLOWED TO CANCEL THE ORDER"
		);
		_collateralToken.transfer(
			_Order.orderer,
			_Order.amount
		);
		_Order.isWhite
			? detailForEvent[_Order.eventId].whiteAmount = detailForEvent[_Order.eventId].whiteAmount.sub(_Order.amount)
			: detailForEvent[_Order.eventId].blackAmount = detailForEvent[_Order.eventId].blackAmount.sub(_Order.amount);
		_Order.isPending = false;
		emit orderCanceled(_orderId);
    }

    function eventStart(uint _eventId) external onlyEventContract {
    	_secondaryPool.buyWhite(_maxPrice, detailForEvent[_eventId].whiteAmount);
    	_secondaryPool.buyBlack(_maxPrice, detailForEvent[_eventId].blackAmount);
    	detailForEvent[_eventId].whitePriceBefore = _secondaryPool._whitePrice();
    	detailForEvent[_eventId].blackPriceBefore = _secondaryPool._blackPrice();
    }

    function eventEnd(uint _eventId) external onlyEventContract {
    	_secondaryPool.sellWhite(_minPrice, detailForEvent[_eventId].whiteAmount);
    	_secondaryPool.sellBlack(_minPrice, detailForEvent[_eventId].blackAmount);
    	detailForEvent[_eventId].whitePriceAfter = _secondaryPool._whitePrice();
    	detailForEvent[_eventId].blackPriceAfter = _secondaryPool._blackPrice();
    	detailForEvent[_eventId].isExecuted = true;
    }

    function withdrawCollateral() external returns(uint) {
        uint totalWithdrawAmount;
        for (uint i = 0; i < ordersOfUser[msg.sender].length; i++) {
            uint _oId = ordersOfUser[msg.sender][i];
            uint _eId = Orders[_oId].eventId;
            if (Orders[_oId].isPending && detailForEvent[_eId].isExecuted) {
                uint withdrawAmount;
                if (Orders[_oId].isWhite) {
                    withdrawAmount = wmul(
                        wdiv(
                            Orders[_oId].amount,
                            detailForEvent[_eId].whitePriceBefore
                        ),
                        detailForEvent[_eId].whitePriceAfter
                    );
                } else {
                    withdrawAmount = wmul(
                        wdiv(
                            Orders[_oId].amount,
                            detailForEvent[_eId].blackPriceBefore
                        ),
                        detailForEvent[_eId].blackPriceAfter
                    );
                }
                totalWithdrawAmount = totalWithdrawAmount.add(withdrawAmount);
            }
        }
        
        uint feeAmount = wmul(totalWithdrawAmount, _FEE);
        uint userWithdrawAmount = totalWithdrawAmount.sub(feeAmount);
        
        _collectedFee = _collectedFee.add(feeAmount);
        _collateralToken.transfer(msg.sender, userWithdrawAmount);
        emit collateralWithdrew(userWithdrawAmount);
        
        delete ordersOfUser[msg.sender];
        
        return totalWithdrawAmount;
    }

    function changeContractOwner(address _newOwnerAddress) external onlyOwner {
		require(
			_newOwnerAddress != address(0),
			"NEW OWNER ADDRESS SHOULD NOT BE NULL"
		);
		transferOwnership(_newOwnerAddress);
		emit contractOwnerChanged(_newOwnerAddress);
	}

	function changeSecondaryPoolAddress(address _newPoolAddress) external onlyOwner {
		require(
			_newPoolAddress != address(0),
			"NEW SECONDARYPOOL ADDRESS SHOULD NOT BE NULL"
		);
		_secondaryPoolAddress = _newPoolAddress;
		emit secondaryPoolAddressChanged(_secondaryPoolAddress);
	}

	function changeEventContractAddress(address _newEventAddress) external onlyOwner {
		require(
			_newEventAddress != address(0),
			"NEW EVENT ADDRESS SHOULD NOT BE NULL"
		);
		_eventContractAddress = _newEventAddress;
		emit eventContractAddressChanged(_eventContractAddress);
	}

	function changeFeeWithdrawAddress(address _newFeeWithdrawAddress) external onlyOwner {
		require(
			_newFeeWithdrawAddress != address(0),
			"NEW WITHDRAW ADDRESS SHOULD NOT BE NULL"
		);
		_feeWithdrawAddress = _newFeeWithdrawAddress;
		emit feeWithdrawAddressChanged(_feeWithdrawAddress);
	}

	function withdrawFee() external onlyOwner {
	    require(
	        _collateralToken.balanceOf(address(this)) >= _collectedFee,
	        "INSUFFICIENT TOKEN(THAT IS LOWER THAN EXPECTED COLLECTEDFEE) IN PENDINGORDERS CONTRACT"
	    );
		_collateralToken.transfer(_feeWithdrawAddress, _collectedFee);
		_collectedFee = 0;
		emit feeWithdrew(_collectedFee);
	}

	function changeFee(uint _newFEE) external onlyOwner {
		_FEE = _newFEE;
		emit feeChanged(_FEE);
	}

}