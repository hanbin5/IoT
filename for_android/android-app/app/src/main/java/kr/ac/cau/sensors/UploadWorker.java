package kr.ac.cau.sensors;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import androidx.work.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.*;

public class UploadWorker extends Worker {
    public UploadWorker(Context c,WorkerParameters p) { super(c,p); }
    static void schedule(Context c,String session,boolean finalPass) {
        OneTimeWorkRequest job = new OneTimeWorkRequest.Builder(UploadWorker.class)
            .setInputData(new Data.Builder().putString("session",session).build())
            .setConstraints(new Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build();
        WorkManager.getInstance(c).enqueueUniqueWork("upload-"+session,
            finalPass ? ExistingWorkPolicy.APPEND_OR_REPLACE : ExistingWorkPolicy.KEEP,job);
    }
    @Override public Result doWork() {
        String s = getInputData().getString("session");
        SQLiteDatabase db = Recordings.open(getApplicationContext()).getWritableDatabase();
        SharedPreferences prefs = getApplicationContext().getSharedPreferences("settings",0);
        long sent;
        try (Cursor totals = db.rawQuery("SELECT COALESCE(SUM(n),0) FROM batches WHERE s=? AND sent=1",new String[]{s})) {
            totals.moveToFirst();
            sent = totals.getLong(0);
        }
        while (!isStopped()) {
            try (Cursor row = db.rawQuery("SELECT b.id,b.payload,t.device,t.meta,t.url FROM batches b JOIN sessions t ON b.s=t.s WHERE b.s=? AND b.sent=0 ORDER BY b.id LIMIT 1",new String[]{s})) {
                if (!row.moveToFirst()) return Result.success();
                long id = row.getLong(0);
                JSONObject body = new JSONObject().put("batchId",id).put("sessionId",s)
                    .put("payload",new JSONArray(row.getString(1))).put("deviceId",row.getString(2))
                    .put("meta",new JSONObject(row.getString(3)));
                HttpURLConnection conn = (HttpURLConnection)new URL(row.getString(4)).openConnection();
                try {
                    conn.setRequestMethod("POST"); conn.setDoOutput(true);
                    conn.setConnectTimeout(10000); conn.setReadTimeout(10000);
                    conn.setRequestProperty("Content-Type","application/json");
                    byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
                    conn.setFixedLengthStreamingMode(data.length);
                    try (OutputStream out = conn.getOutputStream()) { out.write(data); }
                    if (conn.getResponseCode()!=200) throw new IOException("HTTP "+conn.getResponseCode());
                    try (BufferedReader in = new BufferedReader(new InputStreamReader(conn.getInputStream(),StandardCharsets.UTF_8))) {
                        JSONObject reply = new JSONObject(in.readLine());
                        if (!reply.optBoolean("ok") || reply.isNull("session")) throw new IOException("서버 응답 확인 실패");
                        prefs.edit().putString("uploadState","최근 전송 · "+reply.getString("session")+" · 서버 저장 "+(sent+body.getJSONArray("payload").length())+"개").apply();
                    }
                    sent += body.getJSONArray("payload").length();
                    db.execSQL("UPDATE batches SET sent=1 WHERE id=?", new Object[]{id});
                } finally { conn.disconnect(); }
            } catch (Exception e) {
                prefs.edit().putString("uploadState","전송 재시도 대기 · "+e.getMessage()).apply();
                return Result.retry();
            }
        }
        return Result.retry();
    }
}
