import OCR2Commands from '@chainlink/gauntlet-starknet-ocr2'
import ExampleCommands from '@chainlink/gauntlet-starknet-example'
import OZCommands from '@chainlink/gauntlet-starknet-oz'
import StarkgateCommands from '@chainlink/gauntlet-starknet-starkgate'
import ArgentCommands from '@chainlink/gauntlet-starknet-argent'

import { executeCLI } from '@chainlink/gauntlet-core'
import { existsSync } from 'fs'
import path from 'path'
import { io } from '@chainlink/gauntlet-core/dist/utils'

const commands = {
  custom: [...OCR2Commands, ...ExampleCommands, ...OZCommands, ...StarkgateCommands, ...ArgentCommands],
  loadDefaultFlags: () => ({}),
  abstract: {
    findPolymorphic: () => undefined,
    makeCommand: () => undefined,
  },
}

;(async () => {
  try {
    const networkPossiblePaths = [path.join(process.cwd(), 'networks'), path.join(__dirname, '../networks')]
    const networkPath = networkPossiblePaths.filter((networkPath) => existsSync(networkPath))[0]
    const result = await executeCLI(commands, networkPath)
    if (result) {
      io.saveJSON(result, process.env['REPORT_NAME'] ? process.env['REPORT_NAME'] : 'report')
    }
    process.exit(0)
  } catch (e) {
    console.log(e)
    console.log('Starknet Command execution error', e.message)
    process.exitCode = 1
  }
})()