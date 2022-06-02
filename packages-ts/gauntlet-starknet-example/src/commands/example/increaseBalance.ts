import { ExecuteCommandConfig, makeExecuteCommand, Validation } from '@chainlink/gauntlet-starknet'
import { CATEGORIES } from '../../lib/categories'
import { tokenContractLoader } from '../../lib/contracts'

type UserInput = {
  balance: number
}

type ContractInput = [number]

const makeUserInput = async (flags, args): Promise<UserInput> => {
  if (flags.input) return flags.input as UserInput
  return {
    balance: flags.balance,
  }
}

const makeContractInput = async (input: UserInput): Promise<ContractInput> => {
  return [Number(input.balance)]
}

const validate: Validation<UserInput> = async (input) => {
  return true
}

const commandConfig: ExecuteCommandConfig<UserInput, ContractInput> = {
  ux: {
    category: CATEGORIES.EXAMPLE,
    function: 'increase_balance',
    examples: ['token:deploy --network=<NETWORK> --address=<ADDRESS> <CONTRACT_ADDRESS>'],
  },
  makeUserInput,
  makeContractInput,
  validations: [validate],
  loadContract: tokenContractLoader,
}

export default makeExecuteCommand(commandConfig)