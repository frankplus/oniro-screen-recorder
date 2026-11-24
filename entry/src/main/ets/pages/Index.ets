import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ScreenRecorder';
const DOMAIN = 0x0000;

interface Quality {
  label: string;
  width: number;
  height: number;
  bitrate: number;
}

const QUALITIES: Quality[] = [
  { label: '1080p', width: 1080, height: 2400, bitrate: 16000000 },
  { label: '720p', width: 720, height: 1600, bitrate: 8000000 },
  { label: '540p', width: 540, height: 1200, bitrate: 4000000 },
];

@Observed
class Recording {
  name: string;
  path: string;
  size: number;
  mtime: number;

  constructor(name: string, path: string, size: number, mtime: number) {
    this.name = name;
    this.path = path;
    this.size = size;
    this.mtime = mtime;
  }
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function formatDuration(secs: number): string {
  return `${pad(Math.floor(secs / 60))}:${pad(secs % 60)}`;
}

function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${Math.round(bytes / 1024)} KB`;
}

function stamp(d: Date): string {
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_` +
    `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

@Entry
@Component
struct Index {
  @State recording: boolean = false;
  @State busy: boolean = false;
  @State elapsed: number = 0;
  @State qualityIndex: number = 0;
  @State micEnabled: boolean = false;
  @State recordings: Recording[] = [];
  @State playing: string = '';
  @State status: string = '';

  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private recorder: media.AVScreenCaptureRecorder | undefined = undefined;
  private fd: number = -1;
  private currentPath: string = '';
  private timer: number = -1;

  aboutToAppear(): void {
    this.loadRecordings();
  }

  aboutToDisappear(): void {
    if (this.recording) {
      this.stop();
    }
  }

  private recordingsDir(): string {
    const d = `${this.context.filesDir}/recordings`;
    if (!fileIo.accessSync(d)) {
      fileIo.mkdirSync(d);
    }
    return d;
  }

  private loadRecordings(): void {
    const dir = this.recordingsDir();
    const list: Recording[] = [];
    for (const name of fileIo.listFileSync(dir)) {
      const path = `${dir}/${name}`;
      const st = fileIo.statSync(path);
      if (st.size > 0) {
        list.push(new Recording(name, path, st.size, st.mtime));
      } else if (path !== this.currentPath) {
        fileIo.unlinkSync(path);
      }
    }
    list.sort((a, b) => b.mtime - a.mtime);
    this.recordings = list;
  }

  private async requestMic(): Promise<boolean> {
    const perm: Permissions = 'ohos.permission.MICROPHONE';
    const atManager = abilityAccessCtrl.createAtManager();
    const res = await atManager.requestPermissionsFromUser(this.context, [perm]);
    return res.authResults[0] === 0;
  }

  private async start(): Promise<void> {
    if (this.busy || this.recording) {
      return;
    }
    this.busy = true;
    this.status = '';
    try {
      if (this.micEnabled && !(await this.requestMic())) {
        this.micEnabled = false;
        this.getUIContext().getPromptAction().showToast({ message: 'Microphone not allowed: recording internal audio only' });
      }
      const q = QUALITIES[this.qualityIndex];
      this.currentPath = `${this.recordingsDir()}/Screen_${stamp(new Date())}.mp4`;
      const file = fileIo.openSync(this.currentPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      this.fd = file.fd;

      const recorder = await media.createAVScreenCaptureRecorder();
      this.recorder = recorder;
      recorder.on('stateChange', (state: media.AVScreenCaptureStateCode) => this.onState(state));
      recorder.on('error', (err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `capture error ${err.code} ${err.message}`);
        this.status = `Error ${err.code}: ${err.message}`;
        this.finish();
      });
      const config: media.AVScreenCaptureRecordConfig = {
        fd: this.fd,
        frameWidth: q.width,
        frameHeight: q.height,
        videoBitrate: q.bitrate,
        audioSampleRate: 48000,
        audioChannelCount: 2,
        audioBitrate: 128000,
        preset: media.AVScreenCaptureRecordPreset.SCREEN_RECORD_PRESET_H264_AAC_MP4,
        displayId: 0,
      };
      await recorder.init(config);
      await recorder.setMicEnabled(this.micEnabled);
      // Resolves once the request is accepted; the privacy dialog (if any)
      // answers through stateChange STARTED / CANCELED.
      await recorder.startRecording();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `start failed ${err.code} ${err.message}`);
      this.status = `Could not start: ${err.message ?? err.code}`;
      await this.cleanup(true);
    } finally {
      this.busy = false;
    }
  }

  private onState(state: media.AVScreenCaptureStateCode): void {
    hilog.info(DOMAIN, TAG, `state ${state}`);
    switch (state) {
      case media.AVScreenCaptureStateCode.SCREENCAPTURE_STATE_STARTED:
        this.recording = true;
        this.elapsed = 0;
        this.timer = setInterval(() => {
          this.elapsed++;
        }, 1000);
        break;
      case media.AVScreenCaptureStateCode.SCREENCAPTURE_STATE_CANCELED:
        this.status = 'Recording was not allowed';
        this.cleanup(true);
        break;
      case media.AVScreenCaptureStateCode.SCREENCAPTURE_STATE_STOPPED_BY_USER:
      case media.AVScreenCaptureStateCode.SCREENCAPTURE_STATE_INTERRUPTED_BY_OTHER:
      case media.AVScreenCaptureStateCode.SCREENCAPTURE_STATE_STOPPED_BY_CALL:
        this.finish();
        break;
      default:
        break;
    }
  }

  private async stop(): Promise<void> {
    const rec = this.recorder;
    if (this.busy || rec === undefined) {
      return;
    }
    this.busy = true;
    try {
      await rec.stopRecording();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `stop failed ${err.code} ${err.message}`);
    }
    await this.finish();
    this.busy = false;
  }

  private async finish(): Promise<void> {
    await this.cleanup(false);
    this.loadRecordings();
  }

  private async cleanup(discard: boolean): Promise<void> {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.recording = false;
    const rec = this.recorder;
    this.recorder = undefined;
    if (rec !== undefined) {
      try {
        await rec.release();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `release failed ${(e as BusinessError).code}`);
      }
    }
    if (this.fd >= 0) {
      fileIo.closeSync(this.fd);
      this.fd = -1;
    }
    if (discard && this.currentPath !== '' && fileIo.accessSync(this.currentPath)) {
      fileIo.unlinkSync(this.currentPath);
    }
    this.currentPath = '';
  }

  private async saveToGallery(rec: Recording): Promise<void> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.VIDEO, 'mp4');
      const dst = await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY);
      const src = await fileIo.open(rec.path, fileIo.OpenMode.READ_ONLY);
      await fileIo.copyFile(src.fd, dst.fd);
      await fileIo.close(src);
      await fileIo.close(dst);
      this.getUIContext().getPromptAction().showToast({ message: 'Saved to Photos' });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `save failed ${err.code} ${err.message}`);
      this.getUIContext().getPromptAction().showToast({ message: `Save failed: ${err.message}` });
    }
  }

  private remove(rec: Recording): void {
    if (this.playing === rec.path) {
      this.playing = '';
    }
    fileIo.unlinkSync(rec.path);
    this.loadRecordings();
  }

  @Builder
  recordButton() {
    Stack() {
      Circle()
        .width(96)
        .height(96)
        .fill(Color.Transparent)
        .stroke(this.recording ? '#E53935' : '#BDBDBD')
        .strokeWidth(4)
      if (this.recording) {
        Rect().width(36).height(36).radius(6).fill('#E53935')
      } else {
        Circle().width(72).height(72).fill('#E53935')
      }
    }
    .width(96)
    .height(96)
    .opacity(this.busy ? 0.5 : 1)
    .id('recordButton')
    .onClick(() => {
      if (this.recording) {
        this.stop();
      } else {
        this.start();
      }
    })
  }

  @Builder
  recordingItem(rec: Recording) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column() {
          Text(rec.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(Color.White).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${formatSize(rec.size)} · ${new Date(rec.mtime * 1000).toLocaleString()}`)
            .fontSize(12).fontColor('#888888')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.playing === rec.path ? 'Close' : 'Play')
          .fontSize(13).height(32).backgroundColor('#424242')
          .onClick(() => {
            this.playing = this.playing === rec.path ? '' : rec.path;
          })
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Circle })
          .iconSize(18).width(36).height(36)
          .backgroundColor('#1E88E5')
          .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
            if (result === SaveButtonOnClickResult.SUCCESS) {
              this.saveToGallery(rec);
            } else {
              this.getUIContext().getPromptAction().showToast({ message: 'Saving was not allowed' });
            }
          })
        Button('Del')
          .fontSize(13).height(32)
          .backgroundColor('#757575')
          .onClick(() => this.remove(rec))
      }
      .width('100%')

      if (this.playing === rec.path) {
        Video({ src: `file://${rec.path}` })
          .width('100%')
          .height(480)
          .autoPlay(true)
          .controls(true)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Black)
      }
    }
    .padding(12)
    .backgroundColor('#1F1F1F')
    .borderRadius(12)
  }

  build() {
    Column({ space: 20 }) {
      Text('Screen Recorder')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width('100%')

      Column({ space: 16 }) {
        Text(this.recording ? formatDuration(this.elapsed) : 'Ready')
          .fontSize(40)
          .fontColor(this.recording ? '#E53935' : Color.White)
          .fontFamily('monospace')
          .id('timer')

        this.recordButton()

        Text(this.recording ? 'Recording: switch to any app, come back here to stop' :
          'Tap to record the screen')
          .fontSize(13).fontColor('#AAAAAA').textAlign(TextAlign.Center)

        if (this.status !== '') {
          Text(this.status).fontSize(13).fontColor('#FF8A80').textAlign(TextAlign.Center)
        }

        Row({ space: 8 }) {
          Text('Quality').fontSize(15).fontColor(Color.White).margin({ right: 8 })
          ForEach(QUALITIES, (q: Quality, i: number) => {
            Button(q.label)
              .fontSize(13)
              .padding({ left: 4, right: 4 })
              .height(32)
              .layoutWeight(1)
              .enabled(!this.recording)
              .backgroundColor(this.qualityIndex === i ? '#E53935' : '#333333')
              .onClick(() => {
                this.qualityIndex = i;
              })
          }, (q: Quality) => q.label)
        }

        Row() {
          Text('Microphone').fontSize(15).fontColor(Color.White).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.micEnabled })
            .enabled(!this.recording)
            .onChange((on: boolean) => {
              this.micEnabled = on;
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#181818')
      .borderRadius(16)

      Text(`Recordings (${this.recordings.length})`)
        .fontSize(17).fontColor(Color.White).width('100%')

      List({ space: 10 }) {
        ForEach(this.recordings, (rec: Recording) => {
          ListItem() {
            this.recordingItem(rec)
          }
        }, (rec: Recording) => rec.path)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 48, bottom: 16 })
    .backgroundColor('#0D0D0D')
  }
}
