import Foundation

// MARK: - Request Types

struct ClaudeRequest: Codable {
    let model: String
    let maxTokens: Int
    let system: String?
    let tools: [ClaudeTool]?
    let messages: [ClaudeMessage]

    enum CodingKeys: String, CodingKey {
        case model, system, tools, messages
        case maxTokens = "max_tokens"
    }
}

struct ClaudeTool: Codable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

struct ClaudeMessage: Codable {
    let role: String // "user" or "assistant"
    let content: ClaudeContent
}

// MARK: - Content (string or array of blocks)

/// Content can be a plain string or an array of typed content blocks.
/// The Anthropic API accepts both forms for messages and returns arrays in responses.
enum ClaudeContent: Codable {
    case text(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks(try container.decode([ContentBlock].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try container.encode(s)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

// MARK: - Content Blocks

/// A single content block in a message. Discriminated by the `type` field.
///
/// - `text`: Claude's text output
/// - `toolUse`: Claude requesting a tool call
/// - `toolResult`: Our reply with the tool's output
enum ContentBlock: Codable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    // MARK: Discriminator

    private enum TypeKey: String, CodingKey {
        case type
    }

    // MARK: Decodable

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: typeContainer,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    // MARK: Encodable

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        }
    }
}

// MARK: - Concrete Block Types

struct TextBlock: Codable {
    let type: String // always "text"
    let text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

struct ToolUseBlock: Codable {
    let type: String // always "tool_use"
    let id: String
    let name: String
    let input: JSONValue

    init(id: String, name: String, input: JSONValue) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

struct ToolResultBlock: Codable {
    let type: String // always "tool_result"
    let toolUseId: String
    let content: String
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    init(toolUseId: String, content: String, isError: Bool? = nil) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

// MARK: - Response Types

struct ClaudeResponse: Codable {
    let id: String
    let type: String
    let role: String
    let content: [ContentBlock]
    let model: String
    let stopReason: String?
    let usage: Usage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
    }
}

struct Usage: Codable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - API Error Response

struct ClaudeAPIError: Codable {
    let type: String
    let error: ClaudeErrorDetail
}

struct ClaudeErrorDetail: Codable {
    let type: String
    let message: String
}
