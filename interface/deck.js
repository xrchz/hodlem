#!/usr/bin/env node

import * as fs from 'node:fs'
import { ethers } from 'ethers'
import { JsonDB, Config as JsonDBConfig } from 'node-json-db'
import { program } from 'commander'
import { submitPrep, verifyPrep, shuffle, verifyShuffle, decryptCards, revealCards,
         bytesToHex } from './lib.js'

program
  .option('--db <name>', 'json database file name', 'db')
  .option('-r, --rpc <url>', 'RPC provider', 'http://localhost:8545')
  .requiredOption('-d, --deck <addr>', 'address of deck contract')
  .requiredOption('-f, --from <addr>', 'address of sender')
  .option('-a, --abi <path>', 'path to ABI for deck contract', '../build/contracts/Deck.json')

program
  .command('submitPrep')
  .option('-i, --id <num>', 'table id in database', 0)
  .action(async (_, cmd) => {
    const options = cmd.optsWithGlobals()
    const db = new JsonDB(new JsonDBConfig(options.db))
    const socket = {account: {address: options.from}}
    const hash = await submitPrep(db, socket, options.id)
    console.log(bytesToHex(hash))
  })

program
  .command('verifyPrep')
  .option('-i, --id <num>', 'table id in database', 0)
  .action(async (_, cmd) => {
    const options = cmd.optsWithGlobals()
    const db = new JsonDB(new JsonDBConfig(options.db))
    const prep = await verifyPrep(db, {account: {address: options.from}}, options.id)
    const ts = n => console.log(`0x${n.toString(16)}`)
    prep.forEach(p => {
      p.g.forEach(ts)
      p.h.forEach(ts)
      p.gx.forEach(ts)
      p.hx.forEach(ts)
      p.p.gs.forEach(ts)
      p.p.hs.forEach(ts)
      ts(p.p.scx)
    })
  })

/*
const provider = new ethers.providers.JsonRpcProvider(options.rpc)
const deck = new ethers.Contract(options.deck,
  JSON.parse(fs.readFileSync(options.abi, 'utf8')).abi,
  provider)
*/

await program.parseAsync()
