//! Commands as a graph of literal words and typed arguments, in the manner
//! of Brigadier: nodes chain into one another and redirect, so one command
//! can run another for other sources, as `execute as <targets> run <command>`
//! does. Parsing never allocates and never locks, so a dispatcher, once
//! registered, can parse and run commands from any number of threads at
//! once; it also suggests completions and writes usage.
const dispatcher = @import("dispatcher.zig");
pub const Dispatcher = dispatcher.Dispatcher;
pub const Node = dispatcher.Node;
pub const Parsed = dispatcher.Parsed;
pub const Diagnostics = dispatcher.Diagnostics;
pub const RegisterError = dispatcher.RegisterError;
pub const ParseError = dispatcher.ParseError;
pub const message = dispatcher.message;
pub const default_buffer_size = dispatcher.default_buffer_size;

pub const Reader = @import("Reader.zig");

const suggestions = @import("suggestions.zig");
pub const Suggestion = suggestions.Suggestion;
pub const Suggestions = suggestions.Suggestions;
pub const SuggestionBuilder = suggestions.Builder;

pub const arguments = @import("arguments.zig");
pub const ArgumentError = arguments.Error;
pub const Integer = arguments.Integer;
pub const Float = arguments.Float;
pub const Choice = arguments.Choice;
pub const integer = arguments.integer;
pub const float = arguments.float;
pub const choice = arguments.choice;
pub const boolean = arguments.boolean;
pub const word = arguments.word;
pub const string = arguments.string;
pub const greedy = arguments.greedy;

test {
    _ = @import("tests.zig");
}
