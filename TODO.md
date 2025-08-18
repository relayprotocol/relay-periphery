Logic improvements for the next iteration of the periphery contracts:

- pass-through any errors that occur within the executed `calls` (right now we just return a generic "Multicall3 failed" message)
- add support for EIP3009 as implemented [here](https://github.com/base/commerce-payments/blob/3f77761cf8b174fdc456a275a9c64919eda44234/src/collectors/ERC3009PaymentCollector.sol#L42-L50)
- rename `ApprovalProxy` to `RelayApprovalProxy`

Deployment improvements:

- strip CBOR metadata for much simpler deterministic addresses
- use an older EVM version (eg. london)
