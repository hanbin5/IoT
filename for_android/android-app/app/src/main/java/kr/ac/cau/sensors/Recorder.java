package kr.ac.cau.sensors;

import android.app.*;
import android.content.*;
import android.hardware.*;
import android.os.*;
import org.json.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

public class Recorder extends Service implements SensorEventListener {
    public static volatile String phase = "idle", report = "대기 중";
    private final Handler loop = new Handler(Looper.getMainLooper());
    private final ExecutorService disk = Executors.newSingleThreadExecutor();
    private JSONArray pending = new JSONArray();
    private final Map<Integer,float[]> latest = new HashMap<>();
    private final List<String> missing = new ArrayList<>();
    private SensorManager sensors;
    private PowerManager.WakeLock wake;
    private String endpoint;
    private JSONObject meta;
    private String session, device, folder = "", error = "";
    private long offset, started, lastTick, elapsed, lastPressure = -1, saved, lastSchedule;
    private int count, accuracy = -1;
    private boolean destroyed, hasGravity;
    private double hz, pressure = Double.NaN, baseline, altitude;
    private float[] filtered;

    @Override public void onCreate() {
        super.onCreate();
        sensors = getSystemService(SensorManager.class);
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel("capture","센서 수집",NotificationManager.IMPORTANCE_LOW));
    }

    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if (intent == null) return START_NOT_STICKY;
        if ("stop".equals(intent.getAction())) {
            if ("recording".equals(phase)) {
                sensors.unregisterListener(this);
                phase = "draining";
                elapsed = SystemClock.elapsedRealtime() - started;
                hz = 0;
                loop.removeCallbacks(tick);
                persist(true);
            }
            return START_NOT_STICKY;
        }
        if (!"idle".equals(phase)) return START_NOT_STICKY;
        PendingIntent open = PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        startForeground(1,new Notification.Builder(this,"capture").setSmallIcon(android.R.drawable.ic_menu_compass)
                .setContentTitle("센서 수집").setContentText("수집 상태를 보려면 누르세요").setContentIntent(open).setOngoing(true).build());
        try {
            endpoint = intent.getStringExtra("url");
            session = UUID.randomUUID().toString();
            android.content.SharedPreferences prefs = getSharedPreferences("settings",0);
            device = prefs.getString("device",null);
            if (device == null) {
                device = UUID.randomUUID().toString();
                prefs.edit().putString("device",device).apply();
            }
            meta = new JSONObject().put("source","android-app").put("model",Build.MANUFACTURER+" "+Build.MODEL)
                    .put("system","Android "+Build.VERSION.RELEASE).put("startedAt",Instant.now().toString());
            Recordings.open(this).begin(session,device,meta,endpoint);
            started = lastTick = SystemClock.elapsedRealtime();
            offset = System.currentTimeMillis()*1000000L - SystemClock.elapsedRealtimeNanos();
            wake = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"SensorCollector:capture");
            wake.acquire();
            phase = "recording";
            hasGravity = listen(Sensor.TYPE_GRAVITY,"중력(가속도계 추정으로 대체)",10000);
            listen(Sensor.TYPE_GYROSCOPE,"자이로",10000);
            listen(Sensor.TYPE_ROTATION_VECTOR,"자세",10000);
            listen(Sensor.TYPE_MAGNETIC_FIELD,"지자기",10000);
            boolean motion = listen(Sensor.TYPE_ACCELEROMETER,"가속도계",10000);
            boolean baro = listen(Sensor.TYPE_PRESSURE,"기압계",1000000);
            if (!motion && !baro) { finish("수집 가능한 센서가 없습니다"); return START_NOT_STICKY; }
            publish("수집 중");
            loop.postDelayed(tick,1000);
        } catch (Exception ex) { finish("시작 실패 · "+ex.getMessage()); }
        return START_NOT_STICKY;
    }

    private boolean listen(int type,String label,int interval) {
        Sensor s = sensors.getDefaultSensor(type);
        if (s != null && sensors.registerListener(this,s,interval)) return true;
        missing.add(label);
        return false;
    }

    @Override public void onSensorChanged(SensorEvent e) {
        if (!"recording".equals(phase)) return;
        int type = e.sensor.getType();
        try {
            JSONObject v = new JSONObject();
            String name;
            if (type == Sensor.TYPE_PRESSURE) {
                float p = e.values[0];
                if (!(p > 0) || !Float.isFinite(p) || (lastPressure >= 0 && e.timestamp-lastPressure < 950000000L)) return;
                if (lastPressure < 0) baseline = p;
                lastPressure = e.timestamp;
                pressure = p;
                altitude = SensorManager.getAltitude((float)baseline,p);
                v.put("pressure_hpa",pressure).put("rel_alt_m",altitude);
                name = "barometer";
            } else if (type == Sensor.TYPE_ACCELEROMETER) {
                float[] gravity = latest.get(Sensor.TYPE_GRAVITY);
                if (!hasGravity) {
                    if (filtered == null) filtered = e.values.clone();
                    for (int i=0;i<3;i++) filtered[i] += 0.02f*(e.values[i]-filtered[i]);
                    gravity = filtered;
                }
                if (gravity == null) return;
                float[] linear = new float[3];
                for (int i=0;i<3;i++) linear[i] = e.values[i]-gravity[i];
                axes(v,"acc",linear,-1);
                axes(v,"grav",gravity,-1);
                axes(v,"gyro",latest.get(Sensor.TYPE_GYROSCOPE),1);
                axes(v,"mag",latest.get(Sensor.TYPE_MAGNETIC_FIELD),1);
                v.put("mag_accuracy",accuracy);
                float[] rotation = latest.get(Sensor.TYPE_ROTATION_VECTOR);
                float[] q = new float[4];
                if (rotation != null) SensorManager.getQuaternionFromVector(q,rotation);
                for (int i=0;i<4;i++) v.put("quat_"+"wxyz".charAt(i),
                        rotation != null && Float.isFinite(q[i]) ? q[i] : JSONObject.NULL);
                count++;
                name = "motion";
            } else {
                latest.put(type,e.values.clone());
                if (type == Sensor.TYPE_MAGNETIC_FIELD) accuracy = Math.max(-1, Math.min(2,e.accuracy-1));
                return;
            }
            pending.put(new JSONObject().put("name",name).put("time",offset+e.timestamp).put("values",v));
        } catch (JSONException ex) { error = ex.toString(); }
    }

    private static void axes(JSONObject out,String prefix,float[] values,int sign) throws JSONException {
        for (int i=0;i<3;i++) out.put(prefix+"_"+"xyz".charAt(i),
                values != null && Float.isFinite(values[i]) ? sign*values[i] : JSONObject.NULL);
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long now = SystemClock.elapsedRealtime();
            hz = count*1000.0/Math.max(1,now-lastTick);
            elapsed = now-started;
            count = 0;
            lastTick = now;
            persist(false);
            publish("수집 중");
            loop.postDelayed(this,1000);
        }
    };

    private boolean storageFailed;
    private void persist(boolean last) {
        JSONArray batch = pending;
        pending = new JSONArray();
        disk.execute(() -> {
            if (storageFailed) return;
            try {
                if (batch.length()>0) Recordings.open(this).append(session,batch);
                long now = SystemClock.elapsedRealtime();
                if (endpoint != null && (last || lastSchedule == 0 || now-lastSchedule >= 5000)) {
                    UploadWorker.schedule(this,session,last);
                    lastSchedule = now;
                }
                loop.post(() -> {
                    if (destroyed) return;
                    saved += batch.length();
                    if (last) finish("휴대전화 저장 완료");
                });
            } catch (Exception e) {
                storageFailed = true;
                loop.post(() -> {
                    sensors.unregisterListener(this);
                    loop.removeCallbacks(tick);
                    phase = "draining";
                    finish("수집 중단 · "+e.getMessage());
                });
            }
        });
    }

    private void publish(String status) {
        report = String.format(Locale.KOREA,"%s\n\n경과 시간   %d초\n동작 센서   %.1f Hz\n기압   %s\n상대 고도   %s\n휴대전화 저장   %d개",
                status,elapsed/1000,hz,Double.isNaN(pressure)?"–":String.format(Locale.KOREA,"%.2f hPa",pressure),
                Double.isNaN(pressure)?"–":String.format(Locale.KOREA,"%+.2f m",altitude),saved)
                +(missing.isEmpty()?"":"\n미지원 센서   "+String.join(", ",missing));
    }
    private void finish(String message) {
        publish(message);
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }
    @Override public void onDestroy() {
        destroyed = true;
        loop.removeCallbacksAndMessages(null);
        sensors.unregisterListener(this);
        if (wake != null && wake.isHeld()) wake.release();
        disk.shutdown();
        phase = "idle";
        super.onDestroy();
    }
    @Override public void onAccuracyChanged(Sensor s,int accuracy) {}
    @Override public IBinder onBind(Intent i) { return null; }
}
