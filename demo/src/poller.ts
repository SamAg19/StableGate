import ora from 'ora'
import chalk from 'chalk'

interface PollOptions {
  message:        string  // spinner label
  successMessage: string  // printed on condition met
  timeoutMessage: string  // printed on timeout
  intervalMs?:    number  // default 5000
  timeoutMs?:     number  // default 120000 (2 min)
}

export async function pollUntil(
  condition: () => Promise<boolean>,
  opts: PollOptions
): Promise<boolean> {
  const {
    message,
    successMessage,
    timeoutMessage,
    intervalMs = 5_000,
    timeoutMs  = 120_000,
  } = opts

  const spinner  = ora({ text: message, color: 'cyan' }).start()
  const deadline = Date.now() + timeoutMs
  let   elapsed  = 0

  while (Date.now() < deadline) {
    try {
      const met = await condition()
      if (met) {
        spinner.succeed(chalk.green(successMessage))
        return true
      }
    } catch {
      // RPC hiccup — keep polling
    }
    await sleep(intervalMs)
    elapsed += intervalMs
    spinner.text = `${message} ${chalk.grey(`(${Math.floor(elapsed / 1000)}s)`)}`
  }

  spinner.fail(chalk.red(timeoutMessage))
  return false
}

function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms))
}
