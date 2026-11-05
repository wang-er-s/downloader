import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/download_models.dart';
import '../../saved_downloads/domain/saved_download.dart';
import 'providers.dart';

Future<void> showDownloadForm(
  BuildContext context, {
  bool saved = false,
  SavedDownload? initial,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => DownloadForm(saved: saved, initial: initial),
);

class DownloadForm extends ConsumerStatefulWidget {
  const DownloadForm({super.key, this.saved = false, this.initial});
  final bool saved;
  final SavedDownload? initial;
  @override
  ConsumerState<DownloadForm> createState() => _DownloadFormState();
}

class _DownloadFormState extends ConsumerState<DownloadForm> {
  final form = GlobalKey<FormState>();
  late final url = TextEditingController(text: widget.initial?.url);
  late final name = TextEditingController(text: widget.initial?.fileName);
  late final id = widget.initial?.id ?? submissionId();
  late DirectoryLocation? directory = widget.initial?.directory;
  bool submitting = false;
  String? error;
  @override
  void dispose() {
    url.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      submitting = true;
      error = null;
    });
    final controller = ref.read(downloadsControllerProvider.notifier);
    final fileName = name.text.trim().isEmpty ? null : name.text.trim();
    final success = widget.saved
        ? await controller.save(
            SavedDownloadInput(
              id: id,
              url: url.text,
              fileName: fileName,
              directory: directory,
            ),
          )
        : await controller.create(
            CreateDownload(
              requestId: id,
              url: url.text,
              fileName: fileName,
              directory: directory,
            ),
          );
    if (!mounted) return;
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {
        submitting = false;
        error = ref.read(downloadsControllerProvider).error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !submitting,
    child: AlertDialog(
      title: Text(
        widget.saved ? (widget.initial == null ? '新增缓存' : '修改缓存') : '新建下载',
      ),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: url,
                enabled: !submitting,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '下载链接',
                  hintText: 'http / https',
                  prefixIcon: Icon(Icons.link),
                ),
                validator: (value) {
                  try {
                    downloadUrl(value ?? '');
                    return null;
                  } catch (_) {
                    return '请输入有效的 HTTP/HTTPS 链接（无需登录）';
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: name,
                enabled: !submitting,
                decoration: const InputDecoration(
                  labelText: '文件名（可选）',
                  prefixIcon: Icon(Icons.description_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  try {
                    validateFileName(value.trim());
                    return null;
                  } catch (_) {
                    return '文件名不能包含路径或特殊字符';
                  }
                },
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: submitting
                    ? null
                    : () async {
                        final selected = await ref
                            .read(downloadsControllerProvider.notifier)
                            .pickDirectory();
                        if (selected != null && mounted) {
                          setState(() => directory = selected);
                        }
                      },
                icon: const Icon(Icons.folder_outlined),
                label: Text(directory?.displayName ?? '选择保存目录（可选）'),
              ),
              if (directory != null)
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => setState(() => directory = null),
                  child: const Text('使用默认目录'),
                ),
              if (widget.saved) const Text('保存配置不会开始下载。未指定目录时，发起下载采用最新默认目录。'),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (submitting)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('正在提交，请等待实际执行与保存结果…'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: submitting ? null : submit,
          icon: Icon(
            widget.saved ? Icons.bookmark_add_outlined : Icons.download,
          ),
          label: Text(widget.saved ? '保存' : '下载'),
        ),
      ],
    ),
  );
}
