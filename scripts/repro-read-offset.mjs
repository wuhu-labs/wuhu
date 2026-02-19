#!/usr/bin/env node
/**
 * Repro harness for WUHU issue #12: model sometimes calls `read` with `offset: true`.
 *
 * Usage:
 *   node scripts/repro-read-offset.mjs                # uses tool description matching repo (update as needed)
 *   node scripts/repro-read-offset.mjs --variant=old  # older/less-explicit tool description
 *   node scripts/repro-read-offset.mjs --variant=new  # newer/more-explicit tool description
 *   node scripts/repro-read-offset.mjs --tries=5      # run multiple independent inferences
 *
 * Reads OPENAI_API_KEY from:
 *   - process.env.OPENAI_API_KEY, or
 *   - ~/.wuhu/server.yml (llm.openai)
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function parseArgs(argv) {
  const out = {
    variant: 'repo',
    tries: 1,
    model: 'gpt-5.2-codex',
    effort: 'low',
    temperature: NaN,
    offsetHint: '2001',
    noticeStyle: 'range', // range | noRange
    scenario: 'continue', // continue | offsetFlag
  };
  for (const arg of argv.slice(2)) {
    if (arg.startsWith('--variant=')) out.variant = arg.split('=', 2)[1];
    else if (arg.startsWith('--tries=')) out.tries = Number(arg.split('=', 2)[1]);
    else if (arg.startsWith('--model=')) out.model = arg.split('=', 2)[1];
    else if (arg.startsWith('--effort=')) out.effort = arg.split('=', 2)[1];
    else if (arg.startsWith('--temperature=')) out.temperature = Number(arg.split('=', 2)[1]);
    else if (arg.startsWith('--offsetHint=')) out.offsetHint = arg.split('=', 2)[1];
    else if (arg.startsWith('--noticeStyle=')) out.noticeStyle = arg.split('=', 2)[1];
    else if (arg.startsWith('--scenario=')) out.scenario = arg.split('=', 2)[1];
    else if (arg === '--help' || arg === '-h') {
      console.log('See header comment in this file for usage.');
      process.exit(0);
    }
  }
  if (!Number.isFinite(out.tries) || out.tries < 1) out.tries = 1;
  return out;
}

function readOpenAIKey() {
  if (process.env.OPENAI_API_KEY && process.env.OPENAI_API_KEY.trim()) {
    return process.env.OPENAI_API_KEY.trim();
  }

  const serverYml = path.join(os.homedir(), '.wuhu', 'server.yml');
  if (!fs.existsSync(serverYml)) return null;

  const text = fs.readFileSync(serverYml, 'utf8');
  // Very small YAML subset parser for:
  // llm:\n  openai: <key>
  let inLLM = false;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/\t/g, '  ');
    if (!line.trim() || line.trim().startsWith('#')) continue;

    // Top-level key? (no indentation)
    if (/^[^\s].*:$/.test(line)) {
      const key = line.trim().slice(0, -1);
      inLLM = key === 'llm';
      continue;
    }

    if (!inLLM) continue;

    const m = line.match(/^\s*openai\s*:\s*(.+?)\s*$/);
    if (!m) continue;
    let v = m[1].trim();
    // strip quotes if present
    v = v.replace(/^['"]|['"]$/g, '');
    if (v) return v;
  }
  return null;
}

function makeReadTool({ variant }) {
  const parameters = {
    type: 'object',
    properties: {
      path: {
        type: 'string',
        description: 'Path to the file to read (relative or absolute)',
      },
      offset: {
        type: 'integer',
        description: 'Line number to start reading from (1-indexed)',
      },
      limit: {
        type: 'integer',
        description: 'Maximum number of lines to read',
      },
    },
    required: ['path'],
    additionalProperties: false,
  };

  const oldDesc =
    'Read the contents of a text file. Output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files.';

  const repoDesc =
    [
      'Read the contents of a text file.',
      'Output is truncated to 2000 lines or 50KB (whichever is hit first).',
      '',
      'Pagination:',
      '- offset: integer (1-indexed). The first line number to return.',
      '- limit: integer. The maximum number of lines to return.',
      '',
      'IMPORTANT:',
      '- offset/limit MUST be integers (JSON numbers), not booleans or strings.',
      '- To continue after truncation, copy the exact number from the tool output notice.',
      '  Example: if the output says "Use offset=2001 to continue", call read with {"path":"<same file>","offset":2001}.',
    ].join('\n');

  const newDesc =
    [
      'Read the contents of a text file.',
      '',
      'Pagination:',
      '- offset (integer, 1-indexed) is the FIRST line number to return.',
      '- limit (integer) is the maximum number of lines to return.',
      '',
      'IMPORTANT:',
      '- offset/limit MUST be JSON numbers (integers). Do NOT pass true/false or strings.',
      '- To continue after truncation, copy the exact number from the tool output notice, e.g.:',
      '  If the output says "Use offset=2001 to continue", call:',
      '  read({"path":"<same file>","offset":2001})',
    ].join('\n');

  const description =
    variant === 'old' ? oldDesc : variant === 'new' ? newDesc : repoDesc;

  return {
    type: 'function',
    name: 'read',
    description,
    parameters,
    strict: false,
  };
}

function parseToolArgs(args) {
  if (args == null) return null;
  if (typeof args === 'object') return args;
  if (typeof args === 'string') {
    try {
      return JSON.parse(args);
    } catch {
      return { __raw: args };
    }
  }
  return { __raw: args };
}

async function runOnce({ apiKey, model, effort, temperature, variant, offsetHint, noticeStyle, scenario }) {
  const tool = makeReadTool({ variant });

  const systemItem = {
    role: 'system',
    content: [
      {
        type: 'input_text',
        text: [
          'You are a coding agent.',
          'Use tools to inspect and modify the repository in your working directory.',
          'Prefer read/grep/find/ls over guessing file contents.',
          'When making changes, use edit for surgical replacements and write for new files.',
          'Use bash to run builds/tests and gather precise outputs.',
          'Use async_bash to start long-running commands in the background, and async_bash_status to check their status.',
        ].join('\n'),
      },
    ],
  };

  const input = [systemItem];

  if (scenario === 'offsetFlag') {
    input.push({
      role: 'user',
      content: [
        {
          type: 'input_text',
          text: [
            'You MUST call the read tool now.',
            'Read ./README.md.',
            'For the offset parameter: I *think* it can be a boolean flag (true means "continue").',
            'If that is NOT valid per the tool description/schema, ignore my guess and use the correct integer value instead.',
          ].join('\n'),
        },
      ],
    });
  } else {
    // scenario === 'continue'
    // We simulate: assistant previously read a large file and tool returned a truncation notice.
    // Then the user asks to continue.
    input.push(
      {
        role: 'user',
        content: [
          {
            type: 'input_text',
            text: 'Read ./README.md. It is large, so you may need to use offset to continue.',
          },
        ],
      },
      // Simulate prior function call + output.
      {
        type: 'function_call',
        call_id: 'call_1',
        name: 'read',
        arguments: JSON.stringify({ path: './README.md' }),
      },
      {
        type: 'function_call_output',
        call_id: 'call_1',
        output: [
          (() => {
            if (noticeStyle === 'noRange') {
              if (offsetHint === 'none') return '[Output truncated. Use offset to continue.]';
              return `[Output truncated. Use offset=${offsetHint} to continue.]`;
            }

            if (offsetHint === 'none') return '[Showing lines 1-2000 of 3500. Use offset to continue.]';
            return `[Showing lines 1-2000 of 3500. Use offset=${offsetHint} to continue.]`;
          })(),
          '',
          'User request: please continue reading where you left off.',
        ].join('\n'),
      },
      {
        role: 'user',
        content: [
          {
            type: 'input_text',
            text: 'Continue reading from where you left off. Use the offset parameter to continue.',
          },
        ],
      },
    );
  }

  const body = {
    model,
    stream: false,
    input,
    tools: [tool],
    reasoning: effort ? { effort } : undefined,
    temperature: Number.isFinite(temperature) ? temperature : undefined,
  };

  const res = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`Non-JSON response (status ${res.status}): ${text.slice(0, 500)}`);
  }

  if (!res.ok) {
    throw new Error(`OpenAI error (status ${res.status}): ${JSON.stringify(json, null, 2)}`);
  }

  const output = json.output ?? [];
  const calls = output.filter((it) => it.type === 'function_call');
  return { raw: json, calls };
}

async function main() {
  const args = parseArgs(process.argv);
  const apiKey = readOpenAIKey();
  if (!apiKey) {
    console.error('Missing OpenAI key. Set OPENAI_API_KEY or add llm.openai to ~/.wuhu/server.yml');
    process.exit(1);
  }

  console.log(
    `model=${args.model} effort=${args.effort} temp=${args.temperature} variant=${args.variant} scenario=${args.scenario} offsetHint=${args.offsetHint} noticeStyle=${args.noticeStyle} tries=${args.tries}`,
  );

  let sawBoolOffset = 0;
  let sawNumericOffset = 0;
  let sawNoOffset = 0;

  for (let i = 0; i < args.tries; i++) {
    const { calls } = await runOnce({
      apiKey,
      model: args.model,
      effort: args.effort,
      temperature: args.temperature,
      variant: args.variant,
      offsetHint: args.offsetHint,
      noticeStyle: args.noticeStyle,
      scenario: args.scenario,
    });

    const call = calls[0];
    if (!call) {
      console.log(`try ${i + 1}: (no tool call)`);
      continue;
    }

    const parsed = parseToolArgs(call.arguments);
    const offset = parsed?.offset;

    if (offset === true || offset === false) sawBoolOffset++;
    else if (typeof offset === 'number') sawNumericOffset++;
    else if (offset == null) sawNoOffset++;

    console.log(`try ${i + 1}: tool=${call.name} arguments=${call.arguments}`);
  }

  console.log('---');
  console.log(`saw offset boolean: ${sawBoolOffset}`);
  console.log(`saw offset numeric: ${sawNumericOffset}`);
  console.log(`saw offset missing/null: ${sawNoOffset}`);
}

main().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});
