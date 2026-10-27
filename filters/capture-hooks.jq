def prune:
  if type == "object" then
    if has("command") and (.command | type == "string")
       and (.command | test($disabled; "i"))
    then empty
    else
      with_entries(.value |= prune)
      | if has("hooks") and .hooks == [] then empty else . end
    end
  elif type == "array" then map(prune)
  else .
  end;
prune // {}
