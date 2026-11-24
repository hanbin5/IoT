package kr.ac.cau.sensors;

import android.app.Activity;
import android.content.Intent;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import java.net.URI;

public class MainActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private EditText address;
    private Button action, export;
    private CheckBox upload;
    private boolean exporting;
    private java.util.ArrayList<String> exportIds = new java.util.ArrayList<>();
    private TextView status;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null && state.getStringArrayList("exportIds") != null) exportIds = state.getStringArrayList("exportIds");
        ScrollView scroll = new ScrollView(this);
        scroll.setFitsSystemWindows(true);
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(20*getResources().getDisplayMetrics().density);
        form.setPadding(pad,pad,pad,pad);
        scroll.addView(form);
        setContentView(scroll);
        TextView title = new TextView(this);
        title.setText("센서 수집");
        title.setTextSize(28);
        form.addView(title);
        upload = new CheckBox(this);
        upload.setText("네트워크 연결 시 서버에도 전송");
        upload.setChecked(getSharedPreferences("settings",0).getBoolean("upload",false));
        form.addView(upload);
        TextView label = new TextView(this);
        label.setText("서버 주소");
        form.addView(label);
        address = new EditText(this);
        address.setId(View.generateViewId());
        label.setLabelFor(address.getId());
        address.setSingleLine();
        address.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        address.setText(getSharedPreferences("settings",0).getString("url",""));
        form.addView(address);
        action = new Button(this);
        form.addView(action);
        export = new Button(this);
        export.setText("저장한 측정 관리");
        form.addView(export);
        export.setOnClickListener(v -> showRecordings());
        status = new TextView(this);
        status.setTextSize(17);
        status.setTextIsSelectable(true);
        form.addView(status);
        TextView help = new TextView(this);
        help.setPadding(0,pad,0,0);
        help.setText("화면을 꺼도 수집합니다. 측정 후 중지를 누르고 CSV ZIP을 내보낼 수 있습니다.");
        form.addView(help);
        action.setOnClickListener(v -> {
            Intent intent = new Intent(this,Recorder.class);
            if ("recording".equals(Recorder.phase)) startService(intent.setAction("stop"));
            else if ("idle".equals(Recorder.phase)) {
                String url = address.getText().toString().trim();
                if (upload.isChecked()) try {
                    URI uri = new URI(url);
                    if (uri.getHost()==null || !("http".equals(uri.getScheme()) || "https".equals(uri.getScheme())))
                        throw new IllegalArgumentException();
                } catch (Exception ex) { address.setError("http 또는 https 서버 주소를 입력하세요"); return; }
                getSharedPreferences("settings",0).edit().putString("url",url).putBoolean("upload",upload.isChecked()).apply();
                startForegroundService(intent.putExtra("url",upload.isChecked()?url:null));
            }
            action.setEnabled(false);
        });
    }

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            String phase = Recorder.phase;
            address.setEnabled("idle".equals(phase) && upload.isChecked());
            upload.setEnabled("idle".equals(phase));
            export.setEnabled("idle".equals(phase) && !exporting);
            action.setEnabled(!"draining".equals(phase) && !exporting);
            action.setText("idle".equals(phase)?"수집 시작":"recording".equals(phase)?"중지":"저장 중…");
            status.setText(Recorder.report + (upload.isChecked() ? "\n"+getSharedPreferences("settings",0).getString("uploadState","서버 전송 대기") : ""));
            handler.postDelayed(this,400);
        }
    };
    private void showRecordings() {
        exporting = true;
        new Thread(() -> {
            try {
                java.util.LinkedHashMap<String,String> items = Recordings.open(this).list();
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    exporting = false;
                    if (items.isEmpty()) {
                        Toast.makeText(this,"저장한 측정이 없습니다",Toast.LENGTH_SHORT).show();
                        return;
                    }
                    String[] ids = items.keySet().toArray(new String[0]);
                    String[] labels = items.values().toArray(new String[0]);
                    boolean[] checked = new boolean[ids.length];
                    android.app.AlertDialog dialog = new android.app.AlertDialog.Builder(this)
                        .setTitle("측정 선택 ("+ids.length+"개)")
                        .setMultiChoiceItems(labels,checked,(d,index,value) -> checked[index] = value)
                        .setPositiveButton("내보내기",null)
                        .setNeutralButton("삭제",null)
                        .setNegativeButton("닫기",null).create();
                    dialog.setOnShowListener(d -> {
                        dialog.getButton(-1).setOnClickListener(v -> {
                            java.util.ArrayList<String> selected = selection(ids,checked);
                            if (selected.isEmpty()) return;
                            exportIds = selected;
                            dialog.dismiss();
                            startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE).setType("application/zip")
                                .putExtra(Intent.EXTRA_TITLE,"sensor-recordings.zip"),1);
                        });
                        dialog.getButton(-3).setOnClickListener(v -> {
                            java.util.ArrayList<String> selected = selection(ids,checked);
                            if (selected.isEmpty()) return;
                            new android.app.AlertDialog.Builder(this)
                                .setTitle(selected.size()+"개 측정 삭제")
                                .setMessage("선택한 휴대전화 원본을 삭제합니다. 복구할 수 없습니다. 미전송 데이터도 삭제되며 이미 서버에 저장한 데이터는 서버에 남습니다.")
                                .setNegativeButton("취소",null)
                                .setPositiveButton("삭제",(confirm,which) -> {
                                    dialog.dismiss();
                                    deleteRecordings(selected);
                                }).show();
                        });
                    });
                    dialog.show();
                });
            } catch (Exception e) {
                runOnUiThread(() -> {
                    exporting = false;
                    Toast.makeText(this,"목록 조회 실패 · "+e.getMessage(),Toast.LENGTH_LONG).show();
                });
            }
        }).start();
    }
    private java.util.ArrayList<String> selection(String[] ids,boolean[] checked) {
        java.util.ArrayList<String> result = new java.util.ArrayList<>();
        for (int i=0;i<ids.length;i++) if (checked[i]) result.add(ids[i]);
        if (result.isEmpty()) Toast.makeText(this,"측정을 선택하세요",Toast.LENGTH_SHORT).show();
        return result;
    }
    private void deleteRecordings(java.util.ArrayList<String> selected) {
        exporting = true;
        new Thread(() -> {
            String message;
            try {
                for (String id : selected) {
                    androidx.work.WorkManager.getInstance(this).cancelUniqueWork("upload-"+id).getResult().get();
                }
                Recordings.open(this).delete(selected);
                message = selected.size()+"개 측정 삭제 완료";
            } catch (Exception e) { message = "삭제 실패 · "+e.getMessage(); }
            final String text = message;
            runOnUiThread(() -> {
                exporting = false;
                Toast.makeText(this,text,Toast.LENGTH_LONG).show();
                showRecordings();
            });
        }).start();
    }
    @Override protected void onSaveInstanceState(Bundle out) {
        out.putStringArrayList("exportIds",exportIds);
        super.onSaveInstanceState(out);
    }
    @Override protected void onActivityResult(int code,int result,Intent data) {
        super.onActivityResult(code,result,data);
        if (code!=1 || result!=RESULT_OK || data==null || data.getData()==null) return;
        exporting = true;
        new Thread(() -> {
            String message;
            try (java.io.OutputStream out = getContentResolver().openOutputStream(data.getData(),"wt")) {
                if (out==null) throw new java.io.IOException("파일을 열 수 없습니다");
                Recordings.open(this).export(out, exportIds);
                message = "CSV ZIP 저장 완료";
            } catch (Exception e) { message = "내보내기 실패 · "+e.getMessage(); }
            final String resultText = message;
            runOnUiThread(() -> { exporting = false; Toast.makeText(this,resultText,Toast.LENGTH_LONG).show(); });
        }).start();
    }
    @Override protected void onStart() { super.onStart(); refresh.run(); }
    @Override protected void onStop() { handler.removeCallbacks(refresh); super.onStop(); }
}
