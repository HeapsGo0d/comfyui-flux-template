# ComfyUI Flux Template

## organise_downloads.sh Documentation

### Enhanced Debug Logging Features
- Timestamped operations for all file movements
- File size tracking before/after transfers
- Performance metrics (transfer speed, duration)
- Error handling with detailed diagnostics

### Log File Locations
- System logs: `/var/log/organise_downloads.log`
- Debug logs: `~/organise_downloads_debug.log`

### Log Format
```
[YYYY-MM-DD HH:MM:SS] [LEVEL] [OPERATION] - Message
  - Additional details (file sizes, paths, etc.)
```

### Troubleshooting
1. Check debug logs for error details
2. Verify file permissions
3. Monitor system resources during operation

### Performance Optimization
- Uses GNU parallel for concurrent transfers
- Implements batch processing for efficiency
- Includes transfer speed monitoring