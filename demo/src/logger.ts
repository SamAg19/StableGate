import chalk from 'chalk'
import Table from 'cli-table3'

const TOTAL_STEPS = 7

export function banner() {
  console.log(chalk.cyan.bold(`
╔═══════════════════════════════════════════════════════════╗
║              StableGate — Live Testnet Demo               ║
║      Base Sepolia ──▶ Reactive Lasna ──▶ Unichain Sepolia ║
╚═══════════════════════════════════════════════════════════╝
  `))
}

export function step(n: number, title: string) {
  console.log(`\n${chalk.cyan.bold(`[${n}/${TOTAL_STEPS}]`)} ${chalk.white.bold(title)}`)
}

export function success(msg: string) {
  console.log(`  ${chalk.green('\u2713')} ${msg}`)
}

export function info(msg: string) {
  console.log(`  ${chalk.blue('i')} ${msg}`)
}

export function warn(msg: string) {
  console.log(`  ${chalk.yellow('!')} ${msg}`)
}

export function txLink(label: string, hash: string, chain: 'base' | 'unichain') {
  const explorer = chain === 'base'
    ? 'https://sepolia.basescan.org/tx'
    : 'https://sepolia.uniscan.xyz/tx'
  console.log(`  ${chalk.blue('i')} ${label}: ${chalk.underline.cyan(`${explorer}/${hash}`)}`)
}

// Prints a Reactscan link for the RSC — presenter can open this in browser
// during cross-chain wait to show live RSC activity
export function reactscanLink(label: string, contractAddress: string) {
  const url = `https://reactscan.net/rsc/${contractAddress}`
  console.log(`  ${chalk.magenta('*')} ${label}: ${chalk.underline.magenta(url)}`)
}

export function stateTable(title: string, rows: [string, string][]) {
  console.log(`\n  ${chalk.bold(title)}`)
  const table = new Table({
    style: { head: ['cyan'], border: ['grey'] },
    colWidths: [32, 45]
  })
  rows.forEach(([k, v]) => table.push([chalk.grey(k), v]))
  console.log(table.toString())
}

export function sectionDivider() {
  console.log('\n' + chalk.grey('-'.repeat(62)))
}

export function demoComplete() {
  console.log(chalk.green.bold(`
╔═══════════════════════════════════════════════════════════╗
║               Demo Complete — All Steps Passed            ║
╚═══════════════════════════════════════════════════════════╝
  `))
}
