type ToolCall = {
  name: string,
  input: string,
};

function routeTool(call: ToolCall): string {
  if (String.contains(call.name, "search")) {
    return "retrieval";
  }

  if (String.contains(call.name, "issue")) {
    return "tracker";
  }

  return "fallback";
}

let selected = routeTool({
  name: "repo_search",
  input: "find auth middleware",
});

console.log(selected);
