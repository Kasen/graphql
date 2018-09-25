--[[

Temporary notes
---------------

- pattern matchers (match only what that is suitable for index lookup)
- support >, < and so on in find_index
- unit tests for find_index, try to make it reusable
- glue them all
- ----
- each node: suitable index parts: {index,field_no,iterator(=,!=,>,<,>=,<=),key}
- each node: suitable indexes: {index,iterator,key,full_match}
- each node: suitable index-sets: {{suitable indexes},full_match}
- construction:
  - index: // note: should be based on child index-sets, not indexes
    - and:
    - or:
  - index-set:
    - and:
    - or:
- full_match can be superseded with
  - for index: weight = covered child nodes / child nodes
  - for index-set: weight = index weights sum / child nodes
  - the above is wrong weights: it should not be about which part of an
    expr are covered, but about which fraction of the result we covered
- ----
- idea: doing all boolean arithmetic on parts, don't introduce
  index/index-set until end
- idea: we can construct DNF of parts (corr. to CNF of expr ops) during
  tree traversal by expanding and of ors / or of ands and passing negation
  down
- ----
- provide an iterator that merges several iterator results

]]--

local find_expr_index = {}

local cmp_op_to_iterator_type = {
    ['=='] = 'EQ',
    ['!='] = 'NE', -- discarded after all NOT ops processing
    ['>']  = 'GT',
    ['>='] = 'GE',
    ['<']  = 'LT',
    ['<='] = 'LE',
}

-- 42 > x => x < 42
local reverse_iterator_type = {
    ['EQ'] = 'EQ',
    ['NE'] = 'NE',
    ['GT'] = 'LT',
    ['GE'] = 'LE',
    ['LT'] = 'GT',
    ['LE'] = 'GE',
}

-- !(x < 42) => x >= 42
local negate_iterator_type = {
    ['EQ'] = 'NE',
    ['NE'] = 'EQ',
    ['GT'] = 'LE',
    ['GE'] = 'LT',
    ['LT'] = 'GE',
    ['LE'] = 'GT',
}

local function is_cmp_op(op)
    return cmp_op_to_iterator_type[op] ~= nil
end

local function is_const_expr(node)
end

local function evaluate_const_expr(node, context)
end

--- Analyze an expression AST to collect information re useful index parts.
---
--- @tparam table current AST node (e.g. root node)
---
--- @tparam table context table of the following values:
---
--- * variables (table)
--- * parts_map (table)
---
--- @treturn table XXX
local function analyze(node, context)
    if node.kind == 'const' then
        -- XXX: reuse expressions.execute?
        if node.value_class == 'string' then
            return {const_value = node.value}
        elseif node.value_class == 'bool' then
            local value
            if node.value == 'false' then
                value = true
            elseif node.value == 'true' then
                value = false
            else
                error('Unknown boolean node value: ' .. tostring(node.value))
            end
            return {const_value = value}
        elseif node.value_class == 'number' then
            return {const_value = tonumber(node.value)}
        else
            error('Unknown const class: ' .. tostring(node.value_class))
        end
    elseif node.kind == 'variable' then
        -- XXX: reuse expressions.execute?
        return {const_value = context.variables[name.name]}
    elseif node.kind == 'object_field' then
        return {
            field = node.path,
        }
    elseif node.kind == 'func' then
        if node.name == 'regexp' then
        elseif node.name == 'is_null' then
        elseif node.name == 'is_not_null' then
        else
            error('Unknown func name: ' .. tostring(node.name))
        end
    elseif node.kind == 'unary_operation' then
        if node.op == '!' then
        elseif node.op == '+' then
            return analyze(node.node, context)
        elseif node.op == '-' then
        else
            error('Unknown unary operation: ' .. tostring(node.op))
        end
    elseif node.kind == 'binary_operations' then
        -- XXX: traverse from right to left
        for i, op in ipairs(node.operators) do
            local left = execute_node(node.operands[i], context)
            local right = execute_node(node.operands[i + 1], context)

            if is_cmp_op(op) then
                -- XXX: lookup in parts_map here to shrink parts count
                -- XXX: hash index: only EQ and NE
                -- XXX: run analyze on left and right and look at 'field' and
                -- 'const_value' fields
                if left.kind == 'object_field' and is_const_expr(right) then
                    -- XXX: don't return, use recursion
                    return {
                        parts = {
                            {
                                part = left.path,
                                key = evaluate_const_expr(right, context),
                                iterator = cmp_op_to_iterator_type(op),
                            }
                        }
                    }
                elseif is_const_expr(left) and right.kind == 'object_field' then
                    -- XXX: don't return, use recursion
                    return {
                        parts = {
                            {
                                part = left.right,
                                key = evaluate_const_expr(left, context),
                                iterator = reverse_iterator_type[
                                    cmp_op_to_iterator_type(op)],
                            }
                        }
                    }
                else
                    return {parts = {}}
                end
            elseif op == '+' then
            elseif op == '-' then
            elseif op == '&&' then
                -- XXX: union parts
            elseif op == '||' then
                -- XXX: two lists of parts
            else
                error('Unknown binary operation: ' .. tostring(op))
            end
        end
        return acc
    elseif node.kind == 'root_expression' then
        return analyze(node.expr, context)
    else
        error('Unknown node kind: ' .. tostring(node.kind))
    end
end

return find_expr_index
