def test_padd_log_tolerates_system_library_output():
    from ps5mcp.padd_runner import classify as classify_padd
    raw = (b'{"event":"pad_added","ok":true}\n[SceLncUtil] launchApp: LNC_ISOK::0x80940033\n'
           b'{"event":"pad_removed","status":0}\n{"event":"exit_requested","code":0}\n')
    status, records = classify_padd(raw)
    assert status == "passed" and records[1] == {"foreign": "[SceLncUtil] launchApp: LNC_ISOK::0x80940033"}
    assert classify_padd(b'{"event":"pad_added","ok":true}\n')[0] == "running"
    assert classify_padd(b'{"event":"pad_added","ok":true}\n{"event":"exit_req')[0] == "incomplete"
