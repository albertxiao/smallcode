// SmallCode — Prompt Evaluation Runner
// Runs evaluation suites to measure prompt/model quality.
// Supports: classify_accuracy, tool_selection, response_quality

const fs = require('fs');
const path = require('path');

const BUILTIN_SUITES = {
  classify_accuracy: {
    name: 'Task Classification Accuracy',
    cases: [
      { input: 'fix the typo in main.ts', expected: 'coding', tolerance: ['coding', 'refactoring'] },
      { input: 'explain what this function does', expected: 'explanation', tolerance: ['explanation', 'analysis'] },
      { input: 'refactor the database module', expected: 'refactoring', tolerance: ['refactoring', 'coding'] },
      { input: 'write unit tests for auth', expected: 'testing', tolerance: ['testing', 'coding'] },
      { input: 'deploy to production', expected: 'devops', tolerance: ['devops', 'coding'] },
      { input: 'what is dependency injection?', expected: 'explanation', tolerance: ['explanation'] },
      { input: 'add error handling to the API', expected: 'coding', tolerance: ['coding'] },
      { input: 'why is the build failing?', expected: 'debugging', tolerance: ['debugging', 'analysis'] },
      { input: 'rename getUserData to fetchUser', expected: 'refactoring', tolerance: ['refactoring', 'coding'] },
      { input: 'create a new React component', expected: 'coding', tolerance: ['coding'] },
    ],
  },
  tool_selection: {
    name: 'Tool Selection Quality',
    cases: [
      { input: 'read the contents of package.json', expected_tool: 'read_file' },
      { input: 'find all uses of useState', expected_tool: 'grep' },
      { input: 'create a new file called utils.ts', expected_tool: 'write_file' },
      { input: 'run the test suite', expected_tool: 'bash' },
      { input: 'change the function name from foo to bar', expected_tool: 'patch' },
      { input: 'list all files in the project', expected_tool: 'list_projects' },
      { input: 'search for the error message', expected_tool: 'grep' },
      { input: 'install a new package', expected_tool: 'bash' },
    ],
  },
  response_quality: {
    name: 'Response Quality (requires model)',
    cases: [
      { input: 'explain closures in javascript', check: 'length>50', desc: 'response should be substantial' },
      { input: 'fix: const x = 1; x = 2;', check: 'contains:const|let', desc: 'should suggest const→let' },
      { input: '2 + 2', check: 'contains:4', desc: 'basic math' },
    ],
  },
};

class EvalRunner {
  constructor(config) {
    this.config = config;
    this.results = [];
  }

  /**
   * Run a specific evaluation suite.
   * @param {string} suiteName
   * @param {object} opts - { classifyFn, chatCompletionFn, verbose }
   */
  async run(suiteName, opts = {}) {
    const suite = BUILTIN_SUITES[suiteName];
    if (!suite) {
      return { error: `Unknown suite: ${suiteName}. Available: ${Object.keys(BUILTIN_SUITES).join(', ')}` };
    }

    const results = {
      suite: suiteName,
      name: suite.name,
      total: suite.cases.length,
      passed: 0,
      failed: 0,
      cases: [],
    };

    for (const testCase of suite.cases) {
      const caseResult = { input: testCase.input, passed: false };

      if (suiteName === 'classify_accuracy') {
        // Test task classification
        const { classifyTask, classifyTaskAsync } = require('./governor');
        let classified;
        try {
          classified = await classifyTaskAsync(testCase.input);
        } catch {
          classified = classifyTask(testCase.input);
        }
        caseResult.got = classified;
        caseResult.expected = testCase.expected;
        caseResult.passed = testCase.tolerance.includes(classified);
      } else if (suiteName === 'tool_selection') {
        // Test if model picks the right tool
        if (opts.chatCompletionFn) {
          try {
            const messages = [{ role: 'user', content: testCase.input }];
            const response = await opts.chatCompletionFn(this.config, messages);
            const toolCalls = response?.choices?.[0]?.message?.tool_calls;
            const firstTool = toolCalls?.[0]?.function?.name;
            caseResult.got = firstTool || '(no tool)';
            caseResult.expected = testCase.expected_tool;
            caseResult.passed = firstTool === testCase.expected_tool;
          } catch (e) {
            caseResult.got = `error: ${e.message}`;
            caseResult.passed = false;
          }
        } else {
          caseResult.got = '(skipped: no chatCompletion fn)';
          caseResult.passed = false;
        }
      } else if (suiteName === 'response_quality') {
        // Check response properties
        if (opts.chatCompletionFn) {
          try {
            const messages = [{ role: 'user', content: testCase.input }];
            const response = await opts.chatCompletionFn(this.config, messages);
            const content = response?.choices?.[0]?.message?.content || '';
            caseResult.got = content.slice(0, 100);

            if (testCase.check.startsWith('length>')) {
              const minLen = parseInt(testCase.check.split('>')[1]);
              caseResult.passed = content.length > minLen;
            } else if (testCase.check.startsWith('contains:')) {
              const patterns = testCase.check.slice(9).split('|');
              caseResult.passed = patterns.some(p => content.toLowerCase().includes(p));
            }
          } catch (e) {
            caseResult.got = `error: ${e.message}`;
            caseResult.passed = false;
          }
        } else {
          caseResult.got = '(skipped)';
          caseResult.passed = false;
        }
      }

      if (caseResult.passed) results.passed++;
      else results.failed++;
      results.cases.push(caseResult);
    }

    results.score = `${results.passed}/${results.total} (${Math.round(results.passed / results.total * 100)}%)`;
    this.results.push(results);
    return results;
  }

  /**
   * Format results for display.
   */
  static format(results) {
    const lines = [
      `  ${results.name}`,
      `  Score: ${results.score}`,
      `  ${'─'.repeat(40)}`,
    ];
    for (const c of results.cases) {
      const mark = c.passed ? '✓' : '✗';
      const color = c.passed ? '\x1b[32m' : '\x1b[31m';
      lines.push(`  ${color}${mark}\x1b[0m ${c.input.slice(0, 50)} → ${c.got || '?'}${c.expected ? ` (exp: ${c.expected})` : ''}`);
    }
    return lines.join('\n');
  }
}

module.exports = { EvalRunner, BUILTIN_SUITES };
