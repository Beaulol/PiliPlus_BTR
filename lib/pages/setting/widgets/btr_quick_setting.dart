import 'dart:async';

import 'package:PiliPlus/services/btr/proxy.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

/// Edits a draft so changing multiple options reloads playback only once.
class BtrQuickSetting extends StatefulWidget {
  final BtrStats? Function()? stats;
  const BtrQuickSetting({super.key, this.stats});

  @override
  State<BtrQuickSetting> createState() => _BtrQuickSettingState();
}

class _BtrQuickSettingState extends State<BtrQuickSetting> {
  late bool _enabled = Pref.btrEnabled;
  late int _concurrency = Pref.btrConcurrency;
  late int _mode = Pref.btrCdnMode;
  late int _takeover = Pref.btrTakeover;
  late bool _auto = Pref.btrAutoConcurrency;
  Timer? _timer;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.stats != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await GStorage.setting.putAll({
        SettingBoxKey.btrEnabled: _enabled,
        SettingBoxKey.btrConcurrency: _concurrency,
        SettingBoxKey.btrCdnMode: _mode,
        SettingBoxKey.btrTakeover: _takeover,
        SettingBoxKey.btrAutoConcurrency: _auto,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      title: const Text('BTR 加速设置'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('多线程加速'),
              value: _enabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            const Text('工作模式'),
            DropdownButton<int>(
              isExpanded: true,
              value: _takeover,
              items: const [
                DropdownMenuItem(value: 0, child: Text('全接管（增强调度）')),
                DropdownMenuItem(value: 1, child: Text('兼容模式')),
              ],
              onChanged: !_enabled || _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _takeover = value);
                    },
            ),
            Text(
              _takeover == 0
                  ? 'BTR 管理下载、预取和缓存，优先补救慢块；mpv 负责解码播放。'
                  : '按播放器的请求并发下载，保持原有缓冲策略。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动线程数'),
              subtitle: const Text('根据播放缓冲调整，不超过下方上限'),
              value: _auto,
              onChanged: !_enabled || _saving
                  ? null
                  : (value) => setState(() => _auto = value),
            ),
            const Text('并发上限'),
            DropdownButton<int>(
              isExpanded: true,
              value: _concurrency,
              items: const [4, 8, 16, 32]
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text('$value 条连接${value == 8 ? '（推荐）' : ''}'),
                    ),
                  )
                  .toList(),
              onChanged: !_enabled || _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _concurrency = value);
                    },
            ),
            const SizedBox(height: 12),
            const Text('节点模式'),
            DropdownButton<int>(
              isExpanded: true,
              value: _mode,
              items: const [
                DropdownMenuItem(value: 0, child: Text('原始节点')),
                DropdownMenuItem(value: 1, child: Text('大陆节点')),
                DropdownMenuItem(value: 2, child: Text('海外节点')),
              ],
              onChanged: !_enabled || _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _mode = value);
                    },
            ),
            const SizedBox(height: 12),
            if (widget.stats?.call() case final stats?) ...[
              Text(
                '当前连接 ${stats.activeRequests}/${stats.concurrency} · 前方缓冲 ${stats.bufferedAhead.toStringAsFixed(1)} 秒',
              ),
              Text(
                '缓存 ${(stats.cacheBytes / 1048576).toStringAsFixed(1)} MB · 慢块补救 ${stats.hedges} 次',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
            ],
            Text(
              '应用后从当前进度重新加载视频，设置同时保存为默认值。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '应用'),
        ),
      ],
    );
  }
}
