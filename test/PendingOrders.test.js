// const { accounts, contract } = require('@openzeppelin/test-environment');

// const {
//     BN,
//     ether,
//     time,
// } = require('@openzeppelin/test-helpers');

const PendingOrders = artifacts.require('PendingOrders');

contract('PendingOrders', () => {
	let pendingOrders = null;
	before(async () => {
		pendingOrders = await PendingOrders.deployed();
	});

	it('Should create order in the mapping correctly', async () => {
		const oId = await pendingOrders.createOrder(1000, false, 15);
		assert(oId.toString() == '1');
	});
});