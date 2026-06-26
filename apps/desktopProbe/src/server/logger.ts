import { ENV } from '../env';

import { Logger as MezmoLogger, createLogger } from '@logdna/logger';
import { app } from 'electron';

// In dev, the terminal/pipe consuming the Electron process stdout can close
// (e.g. electron-forge's webpack logger restarts) while the app keeps writing
// log lines. The resulting EPIPE is emitted on the stream with no listener,
// which Node escalates to an uncaught exception that crashes the app. Swallow
// broken-pipe errors on the std streams so logging can never take the app down.
for (const stream of [process.stdout, process.stderr]) {
  stream.on('error', (err: NodeJS.ErrnoException) => {
    if (err.code === 'EPIPE') return;
    throw err;
  });
}

export interface ILogger {
  debug(message: string, data?: Record<string, any>): void;
  info(message: string, data?: Record<string, any>): void;
  error(message: string, data?: Record<string, any>): void;
  addMeta(key: string, value: string): void;
  flush(): void;
}

/**
 * Custom logger class that wraps the Mezmo logger.
 */
class Logger implements ILogger {
  constructor(private _logger: MezmoLogger | null) {}

  debug(message: string, data?: Record<string, any>) {
    console.log(message, data);
    this._logger?.debug(message, {
      meta: data,
    });
  }

  info(message: string, data?: Record<string, any>) {
    console.log(message, data);
    this._logger?.info(message, {
      meta: data,
    });
  }

  error(message: string, data?: Record<string, any>) {
    console.error(message, data);
    this._logger?.error(message, {
      meta: data,
    });
  }

  addMeta(key: string, value: string) {
    this._logger?.addMetaProperty(key, value);
  }

  flush() {
    this._logger?.flush();
  }
}

const mezmoLogger = ENV.mezmoApiKey
  ? createLogger(ENV.mezmoApiKey, {
      level: ENV.nodeEnv === 'development' ? 'debug' : 'info',
      app: ENV.appBundleId,
      env: ENV.nodeEnv,
      hostname: process.platform,
      meta: {
        version: app.getVersion(),
        arch: process.arch,
      },
      indexMeta: true,
    })
  : null;
export const logger = new Logger(mezmoLogger);
