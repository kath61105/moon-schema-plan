///|
/// Parse a schema from the stable JSON representation used by the CLI.
pub fn schema_from_json(json : Json) -> Schema raise @json.JsonDecodeError {
  @json.from_json(json)
}

///|
pub fn schema_to_json(schema : Schema) -> Json {
  ToJson::to_json(schema)
}

///|
pub fn plan_to_json(plan : Plan) -> Json {
  ToJson::to_json(plan)
}

///|
pub fn rendered_plan_to_json(plan : RenderedPlan) -> Json {
  ToJson::to_json(plan)
}
