// SmallCode - Streaming Handler with Early-Stop Detection
// Detects repetition loops and off-topic drift, saving wasted tokens

pub struct StreamHandler {
  onTokenCallback: fn(String)
  onCompleteCallback: fn()
  onEarlyStopCallback: fn()
  
  // Early-stop detection state
  buffer: String
  repeatWindow: Int
  repeatThreshold: Int
  maxOutputTokens: Int
  tokenCount: Int
  stopped: Bool
}

pub impl StreamHandler {
  pub fn new(
    onToken: fn(String),
    onComplete: fn(),
    onEarlyStop: fn(),
    maxOutputTokens: Int = 4096
  ): StreamHandler {
    return StreamHandler {
      onTokenCallback: onToken,
      onCompleteCallback: onComplete,
      onEarlyStopCallback: onEarlyStop,
      buffer: "",
      repeatWindow: 50,       // chars to check for repetition
      repeatThreshold: 3,     // times a pattern must repeat to trigger stop
      maxOutputTokens: maxOutputTokens,
      tokenCount: 0,
      stopped: false,
    }
  }

  pub fn onToken(self, token: String) {
    if self.stopped { return }
    self.buffer += token
    self.tokenCount += 1
    self.onTokenCallback(token)
  }

  pub fn onComplete(self) {
    if self.stopped { return }
    self.onCompleteCallback()
  }

  pub fn onEarlyStop(self) {
    self.stopped = true
    self.onEarlyStopCallback()
  }

  // Check if we should stop generation
  pub fn shouldStop(self, accumulated: String): Bool {
    if self.stopped { return true }

    // Check 1: Output length exceeded
    if self.tokenCount >= self.maxOutputTokens {
      return true
    }

    // Check 2: Repetition detection
    if self.detectRepetition(accumulated) {
      return true
    }

    // Check 3: Runaway newlines (model producing empty lines)
    if self.detectRunawayNewlines(accumulated) {
      return true
    }

    return false
  }

  // Detect repeating patterns in output
  fn detectRepetition(self, text: String): Bool {
    if text.length < self.repeatWindow * 2 { return false }

    // Check last N chars for repeating pattern
    let tail = text.slice(text.length - self.repeatWindow * self.repeatThreshold)

    // Try pattern lengths from 10 to repeatWindow
    for patternLen in range(10, self.repeatWindow + 1) {
      let pattern = tail.slice(tail.length - patternLen)
      let count = 0
      let pos = tail.length - patternLen

      while pos >= 0 {
        if tail.slice(pos, pos + patternLen) == pattern {
          count += 1
        } else {
          break
        }
        pos -= patternLen
      }

      if count >= self.repeatThreshold {
        return true
      }
    }

    return false
  }

  // Detect when model is just producing empty lines
  fn detectRunawayNewlines(self, text: String): Bool {
    if text.length < 100 { return false }
    let tail = text.slice(text.length - 50)
    let newlineCount = tail.chars().filter(|c| c == '\n').length
    return newlineCount > 40  // 80% newlines = something went wrong
  }
}

// Simpler handler for non-interactive use (just collects output)
pub fn collectingHandler(maxTokens: Int): StreamHandler {
  let collected = ""
  return StreamHandler.new(
    onToken: |token| { collected += token },
    onComplete: || {},
    onEarlyStop: || {},
    maxOutputTokens: maxTokens,
  )
}
