"""Wire-contract fixture: rejects lost tool results, reasoning state, and ignored settings."""
import json


def task_memory_response(body):
    messages = body['messages']
    functions = [entry['function']['name'] for entry in body['tools']]
    if functions == ['update_task_memory']:
        packet = json.loads(messages[-1]['content'])
        assert 'ORVLET_FAKE_CREDENTIAL' not in json.dumps(packet)
        changes = []
        if any('金额改用美元' in row['text'] for row in packet['messages']):
            assert (any(fact['quote'] == '金额用港币' for fact in packet['existing'])
                    or any('金额用港币' in row['text'] for row in packet['messages'])), 'Missing previous currency evidence'
        for row in packet['messages']:
            for evidence, topic in [('只看港股', '市场'), ('金额用港币', '币种'), ('金额改用美元', '币种')]:
                if evidence in row['text']:
                    changes.append(dict(operation='set', kind='constraint', topic=topic,
                                        source=row['source'], quote=evidence))
        name, arguments = 'update_task_memory', {'changes': changes}
    else:
        facts = [m['content'] for m in messages if m['content'].startswith('Prior task constraint')]
        assert any('只看港股' in f for f in facts) and any('金额改用美元' in f for f in facts), facts
        assert all('港币' not in f for f in facts), facts
        assert 'ORVLET_FAKE_CREDENTIAL' not in str(messages)
        assert all('_orvletContextPriority' not in m for m in messages)
        assert any(m['content'] == '导出时用什么币种？只回复币种。' for m in messages)
        name, arguments = 'finish', {'outcome': 'answer', 'reply': '美元'}
    return 200, {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
        {'id': 'task_memory', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}}]}


def respond(path, body, headers):
    if path.startswith('/api-wire/task-memory/'):
        return task_memory_response(body)
    if path.startswith('/api-wire/decision/'):
        assert headers.get('Authorization') == 'Bearer TEST_DECISION_KEY'
        if path.endswith('/systemone'):
            assert body['model'] == 'jev-latest' and 'state' in body
            assert body['questions']['audio']['type'] == 'noul'
            return 200, {'answers': {'audio': {'type': 'noul', 'noul': .95}}}
        assert path.endswith('/decisions') and body['model'] == 'gpt-6-luna'
        assert 'state' not in body and 'stream' not in body and 'tools' not in body
        assert body['input'][0]['content'][0]['type'] == 'input_json'
        assert isinstance(body['questions'], list)
        answers = []
        for question in body['questions']:
            name = question['name']
            if question['type'] == 'predicate':
                answers.append({'name': name, 'type': 'predicate', 'probability': .95})
            else:
                selected = {'route': 'new', 'instance': 'automatic', 'family': 'general', 'group': 'single', 'delivery': 'unspecified'}[name]
                choices = [option['value'] for option in question['choices']]
                assert selected in choices and all('description' in option for option in question['choices'])
                answers.append({'name': name, 'type': 'choice', 'choice': selected, 'confidence': 1,
                                'probabilities': [{'value': v, 'probability': 1 if v == selected else 0} for v in choices]})
        return 200, {'answers': list(reversed(answers))}
    if '/error' in path:
        return 400, {'error': {'message': 'Unsupported temperature; credential TEST_WIRE_KEY'}}
    if '/chat/' in path:
        assert headers.get('api-key') == 'TEST_WIRE_KEY'
        assert headers.get('X-Provider-Feature') == 'tools'
        assert body['reasoning_effort'] == 'none'
        assert body['max_tokens'] == 512 and body['temperature'] == 0
        assert body['top_p'] == 0.9 and 'parallel_tool_calls' not in body
        assert body['tool_choice']['function']['name'] == 'connection_check'
        return 200, {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
            {'id': 'call_chat', 'type': 'function', 'function': {'name': 'connection_check', 'arguments': '{"ok":true}'}}
        ]}}]}
    if path.startswith('/api-wire/responses'):
        assert body['store'] is False and body['stream'] is False
        assert body['reasoning'] == {'effort': 'none'}
        assert body['tools'][0]['name'] == 'connection_check'
        assert body['tools'][0]['strict'] is False
        assert body['tool_choice'] == {'type': 'function', 'name': 'connection_check'}
        assert body['include'] == ['reasoning.encrypted_content']
        results = [i for i in body['input'] if i.get('type') == 'function_call_output']
        if results:
            assert results == [{'type': 'function_call_output', 'call_id': 'call_resp', 'output': '{"ok":true}'}]
            assert any(i.get('encrypted_content') == 'encrypted-fixture' for i in body['input'])
            assert any(i.get('call_id') == 'call_resp' and i.get('type') == 'function_call' for i in body['input'])
            return 200, {'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'done'}]}]}
        return 200, {'output': [
            {'type': 'reasoning', 'id': 'rs_fixture', 'summary': [], 'encrypted_content': 'encrypted-fixture'},
            {'type': 'function_call', 'id': 'fc_fixture', 'call_id': 'call_resp', 'name': 'connection_check', 'arguments': '{"ok":true}'}]}
    if path.startswith('/api-wire/messages'):
        assert headers.get('x-api-key') == 'TEST_WIRE_KEY'
        assert headers.get('anthropic-version') == '2023-06-01'
        assert body['system'] == 'Fixture instructions'
        assert body['max_tokens'] == 8192
        assert body['tools'][0]['input_schema']['type'] == 'object'
        assert not any(m['role'] == 'system' for m in body['messages'])
        results = [b for m in body['messages'] for b in m['content'] if b['type'] == 'tool_result']
        if results:
            assert [r['tool_use_id'] for r in results] == ['tool_one', 'tool_two']
            assert len(body['messages'][-1]['content']) == 2
            assert body['messages'][-2]['content'][0]['signature'] == 'fixture-signature'
            return 200, {'content': [{'type': 'text', 'text': 'done'}], 'stop_reason': 'end_turn'}
        return 200, {'content': [
            {'type': 'thinking', 'thinking': 'fixture', 'signature': 'fixture-signature'},
            {'type': 'tool_use', 'id': 'tool_one', 'name': 'connection_check', 'input': {'ok': True}},
            {'type': 'tool_use', 'id': 'tool_two', 'name': 'connection_check', 'input': {'ok': True}}], 'stop_reason': 'tool_use'}
    raise AssertionError('Unknown protocol fixture')
