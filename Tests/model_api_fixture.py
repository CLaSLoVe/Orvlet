"""Wire-contract fixture: rejects lost tool results, reasoning state, and ignored settings."""
def respond(path, body, headers):
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
