// SmallCode - Clarifying Questions
// Allows the model to pause and ask the user for clarification
// Detected via a special output pattern, then the TUI prompts the user

import { Terminal, readLine, setColor, resetColor } from "std/terminal"

// Patterns that indicate the model wants to ask a question
const QUESTION_PATTERNS = [
  "<question>",           // Explicit question tag
  "QUESTION:",           // Text-based
  "Could you clarify",
  "Would you like me to",
  "Should I",
  "Which of these",
  "Do you want",
  "I need more information",
  "Please specify",
]

pub struct QuestionHandler {
  terminal: Terminal
  enabled: Bool
}

pub impl QuestionHandler {
  pub fn new(terminal: Terminal, enabled: Bool = true): QuestionHandler {
    return QuestionHandler { terminal: terminal, enabled: enabled }
  }

  // Check if model output contains a question for the user
  pub fn detectQuestion(self, output: String): DetectedQuestion? {
    if !self.enabled { return null }

    // Check for explicit <question> tag
    let tagMatch = output.match("<question>(.*?)</question>")
    if tagMatch {
      return DetectedQuestion {
        question: tagMatch[1].trim(),
        options: extractOptions(tagMatch[1]),
        original: output,
      }
    }

    // Check for question patterns at the end of output
    let lastParagraph = output.split("\n\n").last() ?? ""
    for pattern in QUESTION_PATTERNS {
      if lastParagraph.contains(pattern) && lastParagraph.contains("?") {
        return DetectedQuestion {
          question: lastParagraph.trim(),
          options: extractOptions(lastParagraph),
          original: output,
        }
      }
    }

    return null
  }

  // Prompt the user with the question and get their answer
  pub fn ask(self, question: DetectedQuestion): String {
    println("")
    setColor("yellow")
    println("  ❓ ${question.question}")
    resetColor()

    if question.options.length > 0 {
      for (i, opt) in question.options.enumerate() {
        println("     ${i + 1}. ${opt}")
      }
      println("")
    }

    let answer = readLine("  → ")
    println("")

    // Handle numeric selection
    if question.options.length > 0 {
      let num = parseInt(answer.trim())
      if num && num >= 1 && num <= question.options.length {
        return question.options[num - 1]
      }
    }

    return answer.trim()
  }

  // Strip the question from output (so it's not duplicated)
  pub fn stripQuestion(self, output: String, question: DetectedQuestion): String {
    // Remove <question> tags
    let cleaned = output.replaceAll("<question>.*?</question>", "")
    // Remove the trailing question paragraph
    if cleaned.endsWith(question.question) {
      cleaned = cleaned.slice(0, cleaned.length - question.question.length)
    }
    return cleaned.trim()
  }
}

pub struct DetectedQuestion {
  question: String
  options: List<String>
  original: String
}

// Extract numbered/bulleted options from question text
fn extractOptions(text: String): List<String> {
  let options = []
  let lines = text.split("\n")

  for line in lines {
    let trimmed = line.trim()
    // Match "1. option", "- option", "* option", "a) option"
    let match = trimmed.match("^(?:\\d+[.)\\s]|[-*]\\s|[a-z]\\)\\s)(.+)")
    if match {
      options.push(match[1].trim())
    }
  }

  return options
}
