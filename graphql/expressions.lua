local lpeg = require('lulpeg')
local utils = require('graphql.utils')

--- TODO:
---     1) Validation.
---     2) Big numbers.
---     3) Absence of variable in context.variables is equal
---        to the situation when context.variables.var == nil.

local expressions = {}
local P, R, S, V = lpeg.P, lpeg.R, lpeg.S, lpeg.V
local C = lpeg.C

-- Some special symbols.
local space_symbol = S(' \t\r\n')
local eof = P(-1)
local spaces = space_symbol ^ 0

-- Possible identifier patterns:
--   1) Number.
local digit = R('09')
local integer = R('19') * digit ^ 0
local decimal = (digit ^ 1) * '.' * (digit ^ 1)
local number = decimal + integer
--   2) Boolean.
local bool = P('false') + P('true')
--   3) String.
local string = P('"') * C((P('\\"') + 1 - P('"')) ^ 0) * P('"')
--   4) Variable.
local identifier = ('_' + R('az', 'AZ')) * ('_' + R('09', 'az', 'AZ')) ^ 0
local variable_name = identifier
--   5) Object's field path.
local field_path = identifier * ('.' * identifier) ^ 0

-- Possible logical function patterns:
--   1) is_null.
local is_null = P('is_null')
--   2) is_not_null.
local is_not_null = P('is_not_null')
--   3) regexp.
local regexp = P('regexp')

-- Possible unary operator patterns:
--   1) Logical negation.
local negation = P('!')
--   2) Unary minus.
local unary_minus = P('-')
--   3) Unary plus.
local unary_plus = P('+')

-- Possible binary operator patterns:
--   1) Logical and.
local logic_and = P('&&')
--   2) logical or.
local logic_or = P('||')
--   3) +
local addition = P('+')
--   4) -
local subtraction = P('-')
--   5) ==
local eq = P('==')
--   6) !=
local not_eq = P('!=')
--   7) >
local gt = P('>')
--   8) >=
local ge = P('>=')
--   9) <
local lt = P('<')
--   10) <=
local le = P('<=')

-- AST nodes generating functions.
local function identical(arg)
    return arg
end

local identical_node = identical

local op_name = identical

local function root_expr_node(expr)
    return {
        kind = 'root_expression',
        expr = expr
    }
end

local function bin_op_node(...)
    if select('#', ...) == 1 then
        return select(1, ...)
    end
    local operators = {}
    local operands = {}
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if i % 2 == 0 then
            table.insert(operators, v)
        else
            table.insert(operands, v)
        end
    end
    return {
        kind = 'binary_operations',
        operators = operators,
        operands = operands
    }
end

local function unary_op_node(unary_operator, operand_1)
    return {
        kind = 'unary_operation',
        op = unary_operator,
        node = operand_1
    }
end

local function func_node(name, ...)
    local args = {...}
    return {
        kind = 'func',
        name = name,
        args = args
    }
end

local function number_node(value)
    return {
        kind = 'const',
        value_class = 'number',
        value = value
    }
end

local function string_node(value)
    return {
        kind = 'const',
        value_class = 'string',
        value = value
    }
end

local function bool_node(value)
    return {
        kind = 'const',
        value_class = 'bool',
        value = value
    }
end

local function variable_node(name)
    return {
        kind = 'variable',
        name = name
    }
end

local function path_node(path)
    return {
        kind = 'object_field',
        path = path
    }
end

-- Patterns returning corresponding nodes (note that all of them
-- start with '_').
local _number = number / number_node
local _bool = bool / bool_node
local _string = string / string_node
local _variable = '$' * C(variable_name) / variable_node
local _field_path = field_path / path_node
local _literal = _bool + _number + _string

local _logic_or = logic_or / op_name
local _logic_and = logic_and / op_name
local _comparison_op = (eq + not_eq + ge + gt + le + lt) / op_name
local _arithmetic_op = (addition + subtraction) / op_name
local _unary_op = (negation + unary_minus + unary_plus) / op_name
local _functions = (is_null + is_not_null + regexp) / identical

-- Grammar rules for C-style expressions positioned ascending in
-- terms of priority.
local expression_grammar = P {
    'init_expr',
    init_expr = V('expr') * eof / root_expr_node,
    expr = spaces * V('log_expr_or') * spaces / identical_node,

    log_expr_or = V('log_expr_and') * (spaces * _logic_or *
                  spaces * V('log_expr_and')) ^ 0 / bin_op_node,
    log_expr_and = V('comparison') * (spaces * _logic_and * spaces *
                   V('comparison')) ^ 0 / bin_op_node,
    comparison = V('arithmetic_expr') * (spaces * _comparison_op * spaces *
                 V('arithmetic_expr')) ^ 0 / bin_op_node,
    arithmetic_expr = V('unary_expr') * (spaces * _arithmetic_op * spaces *
                      V('unary_expr')) ^ 0 / bin_op_node,

    unary_expr = (_unary_op * V('first_prio') / unary_op_node) +
                 (V('first_prio') / identical_node),
    first_prio = (V('func') + V('value_terminal') + '(' * spaces * V('expr') *
                  spaces * ')') / identical_node,
    func = _functions * '(' * spaces * V('value_terminal') * (spaces * ',' *
           spaces * V('value_terminal')) ^ 0 * spaces * ')' / func_node,
    value_terminal = (_literal + _variable + _field_path) / identical_node
}

-- Add one number to another.
--
-- It may be changed after introduction of "big ints".
--
-- @param operand_1
-- @param operand_2
local function sum(operand_1, operand_2)
    return operand_1 + operand_2
end

-- Subtract one number from another.
--
-- It may be changed after introduction of "big ints".
--
-- @param operand_1
-- @param operand_2
local function subtract(operand_1, operand_2)
    return operand_1 - operand_2
end

--- Parse given string which supposed to be a c-style expression.
---
--- @tparam string str string representation of expression
---
--- @treturn table syntax tree
local function parse(str)
    assert(type(str) == 'string', 'parser expects a string')
    return expression_grammar:match(str) or error('syntax error')
end

--local function validate(context)
--
--end

--- Recursively execute the syntax subtree. Of course it can be
--- syntax tree itself.
---
--- @tparam table node    node to be executed
---
--- @tparam table context table containing information useful for
---                       execution (see @{expressions.new})
---
--- @return subtree value
local function execute_node(node, context)
    if node.kind == 'const' then
        if node.value_class == 'string' then
            return node.value
        end

        if node.value_class == 'bool' then
            if node.value == 'false' then
                return false
            end
            return true
        end

        if node.value_class == 'number' then
            return tonumber(node.value)
        end
    end

    if node.kind == 'variable' then
        local name = node.name
        return context.variables[name]
    end

    if node.kind == 'object_field' then
        local path = node.path
        local field = context.object
        local table_path = (path:split('.'))
        for i = 1, #table_path do
            field = field[table_path[i]]
        end
        return field
    end

    if node.kind == 'func' then
        -- regexp() implementation.
        if node.name == 'regexp' then
            return utils.regexp(execute_node(node.args[1], context),
                                execute_node(node.args[2], context))
        end

        -- is_null() implementation.
        if node.name == 'is_null' then
            return execute_node(node.args[1], context) == nil
        end

        -- is_not_null() implementation.
        if node.name == 'is_not_null' then
            return execute_node(node.args[1], context) ~= nil
        end
    end

    if node.kind == 'unary_operation' then
        -- Negation.
        if node.op == '!' then
            return not execute_node(node.node, context)
        end

        -- Unary '+'.
        if node.op == '+' then
            return execute_node(node.node, context)
        end

        -- Unary '-'.
        if node.op == '-' then
            return -execute_node(node.node, context)
        end
    end

    if node.kind == 'binary_operations' then
        local prev = execute_node(node.operands[1], context)
        for i, op in ipairs(node.operators) do
            local second_operand = execute_node(node.operands[i + 1],
                                                context)
            -- Sum.
            if op == '+' then
                prev = sum(prev, second_operand)
            end

            -- Subtraction.
            if op == '-' then
                prev = subtract(prev, second_operand)
            end

            -- Logical and.
            if op == '&&' then
                prev = prev and second_operand
            end

            -- Logical or.
            if op == '||' then
                prev = prev or second_operand
            end

            -- Equal.
            if op == '==' then
                prev = prev == second_operand
            end

            -- Not equal.
            if op == '!=' then
                prev = prev ~= second_operand
            end

            -- Greater than.
            if op == '>' then
                prev = prev > second_operand
            end

            -- Greater or equal.
            if op == '>=' then
                prev = prev >= second_operand
            end

            -- Lower than.
            if op == '<' then
                prev = prev < second_operand
            end

            -- Lower or equal.
            if op == '&&' then
                prev = prev and second_operand
            end
        end
        return prev
    end

    if node.kind == 'root_expression' then
        return execute_node(node.expr, context)
    end
end

local function expr_execute(self, object, variables)
    local context = {
        object = object,
        variables = variables,
    }
    return execute_node(self.ast, context)
end

--- Compile and execute given string that represents a c-style
--- expression.
---
--- @tparam string str       string representation of expression
--- @tparam table  object    object considered inside of an
---                          expression
--- @tparam table  variables list of variables
---
--- @return expression value
function expressions.execute(str, object, variables)
    local expr = expressions.new(str)
    return expr:execute(object, variables)
end

--- Create a new c-style expression object.
---
--- @tparam string str string representation of expression
---
--- @treturn table expression object
function expressions.new(str)
    local ast = parse(str)

    return setmetatable({
        raw = str,
        ast = ast,
    }, {
        __index = {
            execute = expr_execute,
        }
    })
end

return expressions