/* eslint-disable no-param-reassign */
const BigNumber = require('bignumber.js')
const Web3Utils = require('web3').utils
const assert = require('assert')
const {
  web3Home,
  web3Foreign,
  deploymentAddress,
  GAS_LIMIT_EXTRA,
  HOME_DEPLOYMENT_GAS_PRICE,
  FOREIGN_DEPLOYMENT_GAS_PRICE,
  HOME_EXPLORER_URL,
  FOREIGN_EXPLORER_URL,
  HOME_EXPLORER_API_KEY,
  FOREIGN_EXPLORER_API_KEY,
  DEPLOYMENT_ACCOUNT_PRIVATE_KEY,
} = require('./web3')
const verifier = require('./utils/verifier')

async function deployContract(contractJson, args, { network, nonce }) {
  let web3
  let apiUrl
  let apiKey
  if (network === 'foreign') {
    web3 = web3Foreign
    apiUrl = FOREIGN_EXPLORER_URL
    apiKey = FOREIGN_EXPLORER_API_KEY
  } else {
    web3 = web3Home
    apiUrl = HOME_EXPLORER_URL
    apiKey = HOME_EXPLORER_API_KEY
  }
  const instance = new web3.eth.Contract(contractJson.abi)
  const result = instance
    .deploy({
      data: contractJson.bytecode,
      arguments: args,
    })
    .encodeABI()
  const receipt = await sendTx(network, {
    data: result,
    nonce,
    to: null,
  })
  instance.options.address = receipt.contractAddress
  instance.deployedBlockNumber = receipt.blockNumber

  if (apiUrl) {
    let constructorArguments
    if (args.length) {
      constructorArguments = result.substring(contractJson.bytecode.length)
    }
    await verifier({ artifact: contractJson, constructorArguments, address: receipt.contractAddress, apiUrl, apiKey })
  }

  return instance
}

function sendTx(network, options) {
  return (network === 'foreign' ? sendRawTxForeign : sendRawTxHome)(options)
}

async function sendRawTxHome(options) {
  return sendRawTx({
    ...options,
    gasPrice: HOME_DEPLOYMENT_GAS_PRICE,
    web3: web3Home,
  })
}

async function sendRawTxForeign(options) {
  return sendRawTx({
    ...options,
    gasPrice: FOREIGN_DEPLOYMENT_GAS_PRICE,
    web3: web3Foreign,
  })
}

async function sendRawTx({ data, nonce, to, web3, gasPrice, value }) {
  try {
    const estimatedGas = new BigNumber(
      await web3.eth.estimateGas({
        from: deploymentAddress,
        value,
        to,
        data,
      })
    )

    const blockData = await web3.eth.getBlock('latest')
    const blockGasLimit = new BigNumber(blockData.gasLimit)
    if (estimatedGas.isGreaterThan(blockGasLimit)) {
      throw new Error(
        `estimated gas greater (${estimatedGas.toString()}) than the block gas limit (${blockGasLimit.toString()})`
      )
    }
    let gas = estimatedGas.multipliedBy(new BigNumber(1 + GAS_LIMIT_EXTRA))
    if (gas.isGreaterThan(blockGasLimit)) {
      gas = blockGasLimit
    } else {
      gas = gas.toFixed(0)
    }

    const rawTx = {
      nonce,
      gasPrice: Web3Utils.toHex(gasPrice),
      gasLimit: Web3Utils.toHex(gas),
      to,
      data,
      value,
    }

    const signedTx = await web3.eth.accounts.signTransaction(rawTx, DEPLOYMENT_ACCOUNT_PRIVATE_KEY)
    const receipt = await web3.eth
      .sendSignedTransaction(signedTx.rawTransaction)
      .once('transactionHash', (txHash) => console.log('pending txHash', txHash))
      .on('error', (e) => {
        throw e
      })
    assert.ok(receipt.status, 'Transaction Failed')
    return receipt
  } catch (e) {
    console.error(e)
  }
  return null
}

async function upgradeProxy({ proxy, implementationAddress, version, nonce, network }) {
  await sendTx(network, {
    data: proxy.methods.upgradeTo(version, implementationAddress).encodeABI(),
    nonce,
    to: proxy.options.address,
  })
}

async function transferProxyOwnership({ proxy, newOwner, nonce, network }) {
  await sendTx(network, {
    data: proxy.methods.transferProxyOwnership(newOwner).encodeABI(),
    nonce,
    to: proxy.options.address,
  })
}

async function transferOwnership({ contract, newOwner, nonce, network }) {
  await sendTx(network, {
    data: contract.methods.transferOwnership(newOwner).encodeABI(),
    nonce,
    to: contract.options.address,
  })
}

async function setBridgeContract({ contract, bridgeAddress, nonce, network }) {
  await sendTx(network, {
    data: contract.methods.setBridgeContract(bridgeAddress).encodeABI(),
    nonce,
    to: contract.options.address,
  })
}

// Allows the mediator to deploy tokens through the token factory.
// Sends the tx if the deployment account owns the factory, otherwise prints the call for the owner.
// Returns the next nonce.
async function allowTokenFactoryDeployer({ factory, mediator, nonce, network }) {
  if (await factory.methods.isDeployer(mediator).call()) {
    return nonce
  }
  const data = factory.methods.setDeployer(mediator, true).encodeABI()
  const owner = await factory.methods.owner().call()
  if (owner.toLowerCase() !== deploymentAddress.toLowerCase()) {
    console.log(`Token factory owner (${owner}) must call setDeployer(mediator, true):
    to: ${factory.options.address}
    data: ${data}`)
    return nonce
  }
  await sendTx(network, { data, nonce, to: factory.options.address })
  console.log('Token factory: mediator allowed as deployer')
  return nonce + 1
}

async function isContract(web3, address) {
  const code = await web3.eth.getCode(address)
  return code !== '0x' && code !== '0x0'
}

module.exports = {
  deployContract,
  sendRawTxHome,
  sendRawTxForeign,
  upgradeProxy,
  transferProxyOwnership,
  transferOwnership,
  setBridgeContract,
  allowTokenFactoryDeployer,
  isContract,
}
